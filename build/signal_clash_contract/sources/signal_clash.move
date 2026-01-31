module signal_clash::signal_clash {
    use std::vector;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    use pyth::i64::{Self as pyth_i64, I64};
    use pyth::price_identifier;
    use pyth::price_info::{Self as pyth_price_info, PriceInfoObject};

    use signal_clash::oracle_mock;
    use signal_clash::oracle_pyth;

    /// Direction constants.
    const DIR_DOWN: u8 = 0;
    const DIR_UP: u8 = 1;

    /// Outcome constants.
    const OUTCOME_DOWN: u8 = 0;
    const OUTCOME_UP: u8 = 1;
    const OUTCOME_TIE: u8 = 2;

    const E_BATTLE_NOT_FOUND: u64 = 0;
    const E_BATTLE_CLOSED: u64 = 1;
    const E_NOT_OPEN_YET: u64 = 2;
    const E_ALREADY_JOINED: u64 = 3;
    const E_INVALID_DIRECTION: u64 = 4;
    const E_TOO_EARLY_TO_CLOSE: u64 = 5;
    const E_BATTLE_NOT_CLOSED: u64 = 6;
    const E_NOT_PARTICIPANT: u64 = 7;
    const E_ALREADY_CLAIMED: u64 = 8;
    const E_STAKE_TOO_SMALL: u64 = 9;
    const E_INVALID_TIME: u64 = 10;
    const E_NO_WINNERS: u64 = 11;
    const E_NOT_FEE_RECIPIENT: u64 = 12;
    const E_NEGATIVE_PYTH_PRICE: u64 = 13;
    const E_PYTH_EXPO_MISMATCH: u64 = 14;
    const E_PYTH_FEED_MISMATCH: u64 = 15;
    const E_BATTLE_NOT_PYTH: u64 = 16;

    /// Shared game object.
    ///
    /// - Holds all battles
    /// - Holds accumulated platform fees
    /// - Fee is a flat amount (e.g. 5 USDT) charged on join
    public struct Arena<phantom CoinType> has key, store {
        id: UID,
        fee_flat: u64,
        fee_recipient: address,
        fees: Balance<CoinType>,
        next_battle_id: u64,
        battles: Table<u64, Battle<CoinType>>,
    }

    /// Per-user position (one per battle).
    public struct Position has store {
        direction: u8,
        stake: u64,
        claimed: bool,
    }

    /// Battle state.
    ///
    /// NOTE: for now we support exactly 1 asset (index 0), but we keep vector fields
    /// to match your roadmap for multi-asset battles.
    public struct Battle<phantom CoinType> has store {
        /// Price identifier bytes (for Pyth this is 32 bytes).
        assets: vector<vector<u8>>,

        /// Legacy/simple numeric prices (used by oracle_mock path).
        /// For Pyth battles we store the *magnitude* of the I64 price (requires expo match).
        open_prices: vector<u64>,
        close_prices: vector<u64>,

        /// Pyth-native price representation.
        has_pyth: bool,
        open_price_pyth: I64,
        open_expo_pyth: I64,
        close_price_pyth: I64,
        close_expo_pyth: I64,

        open_time: u64,
        close_time: u64,
        is_closed: bool,
        outcome: u8,

        /// Pool size snapshot taken at close time, so pro-rata payouts don't depend
        /// on claim ordering.
        pool_at_close: u64,

        pool: Balance<CoinType>,
        total_up: u64,
        total_down: u64,

        positions: Table<address, Position>,
    }

    /// Events
    public struct BattleCreated has copy, drop {
        battle_id: u64,
        open_time: u64,
        close_time: u64,
        open_price: u64,
    }

    public struct Joined has copy, drop {
        battle_id: u64,
        player: address,
        direction: u8,
        stake: u64,
    }

    public struct BattleClosed has copy, drop {
        battle_id: u64,
        close_price: u64,
        outcome: u8,
    }

    public struct Claimed has copy, drop {
        battle_id: u64,
        player: address,
        payout: u64,
    }

    fun bytes_eq(a: &vector<u8>, b: &vector<u8>): bool {
        let n = vector::length(a);
        if (n != vector::length(b)) {
            return false
        };

        let mut i = 0;
        while (i < n) {
            if (*vector::borrow(a, i) != *vector::borrow(b, i)) {
                return false
            };
            i = i + 1;
        };

        true
    }

    /// Non-entry constructor (useful for tests).
    public fun new_arena<CoinType>(
        fee_flat: u64,
        fee_recipient: address,
        ctx: &mut TxContext,
    ): Arena<CoinType> {
        Arena<CoinType> {
            id: object::new(ctx),
            fee_flat,
            fee_recipient,
            fees: balance::zero(),
            next_battle_id: 0,
            battles: table::new(ctx),
        }
    }

    /// Initialize and share the Arena.
    ///
    /// fee_flat example: for "5 USDT" you likely want 5 * 10^decimals (depends on the token decimals).
    public entry fun init_arena<CoinType>(
        fee_flat: u64,
        fee_recipient: address,
        ctx: &mut TxContext,
    ) {
        let arena = new_arena<CoinType>(fee_flat, fee_recipient, ctx);
        transfer::public_share_object(arena);
    }

    /// Create a battle using an on-chain oracle snapshot for the open price.
    ///
    /// For now, this uses `signal_clash::oracle_mock`.
    public entry fun create_battle_from_oracle<CoinType>(
        arena: &mut Arena<CoinType>,
        oracle: &oracle_mock::Oracle,
        asset_price_id: vector<u8>,
        open_time: u64,
        close_time: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let open_price = oracle_mock::get_price(oracle, &asset_price_id);
        create_battle<CoinType>(arena, asset_price_id, open_time, close_time, open_price, clock, ctx)
    }

    /// Create a battle using Pyth price feed (pull oracle model).
    ///
    /// The client must update the Pyth price in the same transaction before calling this.
    public entry fun create_battle_from_pyth<CoinType>(
        arena: &mut Arena<CoinType>,
        price_info_object: &PriceInfoObject,
        open_time: u64,
        close_time: u64,
        max_age_secs: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Extract price id bytes from the price info object
        let info = pyth_price_info::get_price_info_from_price_info_object(price_info_object);
        let pid = pyth_price_info::get_price_identifier(&info);
        let id_bytes = price_identifier::get_bytes(&pid);

        // Read a fresh price
        let (open_price_pyth, open_expo_pyth) = oracle_pyth::get_price_no_older_than(
            price_info_object,
            clock,
            max_age_secs,
        );
        assert!(!pyth_i64::get_is_negative(&open_price_pyth), E_NEGATIVE_PYTH_PRICE);

        let open_mag = pyth_i64::get_magnitude_if_positive(&open_price_pyth);

        // create battle using magnitude (u64) for legacy open_prices[0]
        let battle_id = arena.next_battle_id;
        create_battle<CoinType>(arena, id_bytes, open_time, close_time, open_mag, clock, ctx);

        // mark this battle as Pyth-based
        let battle = table::borrow_mut(&mut arena.battles, battle_id);
        battle.has_pyth = true;
        battle.open_price_pyth = open_price_pyth;
        battle.open_expo_pyth = open_expo_pyth;
    }

    /// Create a battle (caller supplies open_price).
    ///
    /// In production you should obtain `open_price` from Pyth (or other oracle) inside
    /// the same PTB/tx that calls this function.
    public entry fun create_battle<CoinType>(
        arena: &mut Arena<CoinType>,
        asset_price_id: vector<u8>,
        open_time: u64,
        close_time: u64,
        open_price: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now = clock::timestamp_ms(clock);
        assert!(now <= open_time, E_INVALID_TIME);
        assert!(open_time <= close_time, E_INVALID_TIME);

        let battle_id = arena.next_battle_id;
        arena.next_battle_id = battle_id + 1;

        let mut assets = vector::empty<vector<u8>>();
        vector::push_back(&mut assets, asset_price_id);

        let mut open_prices = vector::empty<u64>();
        vector::push_back(&mut open_prices, open_price);

        let close_prices = vector::empty<u64>();

        let zero_i64 = pyth_i64::new(0, false);

        let battle = Battle<CoinType> {
            assets,
            open_prices,
            close_prices,
            has_pyth: false,
            open_price_pyth: zero_i64,
            open_expo_pyth: zero_i64,
            close_price_pyth: zero_i64,
            close_expo_pyth: zero_i64,
            open_time,
            close_time,
            is_closed: false,
            outcome: OUTCOME_TIE,
            pool_at_close: 0,
            pool: balance::zero(),
            total_up: 0,
            total_down: 0,
            positions: table::new(ctx),
        };

        table::add(&mut arena.battles, battle_id, battle);
        event::emit(BattleCreated { battle_id, open_time, close_time, open_price });
    }

    /// Join battle (one position per user).
    ///
    /// - User deposits `Coin<CoinType>`
    /// - Contract charges a flat fee (`arena.fee_flat`) into `arena.fees`
    /// - Remaining stake goes into the battle pool
    public entry fun join_battle<CoinType>(
        arena: &mut Arena<CoinType>,
        battle_id: u64,
        stake_coin: Coin<CoinType>,
        direction: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        join_battle_impl(
            arena,
            battle_id,
            stake_coin,
            direction,
            tx_context::sender(ctx),
            clock,
            ctx,
        )
    }

    #[test_only]
    public fun join_battle_for_testing<CoinType>(
        arena: &mut Arena<CoinType>,
        battle_id: u64,
        stake_coin: Coin<CoinType>,
        direction: u8,
        sender: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        join_battle_impl(arena, battle_id, stake_coin, direction, sender, clock, ctx)
    }

    fun join_battle_impl<CoinType>(
        arena: &mut Arena<CoinType>,
        battle_id: u64,
        mut stake_coin: Coin<CoinType>,
        direction: u8,
        sender: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(direction == DIR_UP || direction == DIR_DOWN, E_INVALID_DIRECTION);
        assert!(table::contains(&arena.battles, battle_id), E_BATTLE_NOT_FOUND);

        let battle = table::borrow_mut(&mut arena.battles, battle_id);
        assert!(!battle.is_closed, E_BATTLE_CLOSED);

        let now = clock::timestamp_ms(clock);
        assert!(now >= battle.open_time, E_NOT_OPEN_YET);
        assert!(now < battle.close_time, E_BATTLE_CLOSED);

        assert!(!table::contains(&battle.positions, sender), E_ALREADY_JOINED);

        let stake_value = stake_coin.value();
        assert!(stake_value > arena.fee_flat, E_STAKE_TOO_SMALL);

        // Split fee
        let fee_coin = stake_coin.split(arena.fee_flat, ctx);
        arena.fees.join(fee_coin.into_balance());

        // Remaining stake -> pool
        let net_stake = stake_coin.value();
        battle.pool.join(stake_coin.into_balance());

        if (direction == DIR_UP) {
            battle.total_up = battle.total_up + net_stake;
        } else {
            battle.total_down = battle.total_down + net_stake;
        };

        table::add(
            &mut battle.positions,
            sender,
            Position {
                direction,
                stake: net_stake,
                claimed: false,
            },
        );

        event::emit(Joined { battle_id, player: sender, direction, stake: net_stake });
    }

    /// Close battle by reading the close price from the oracle.
    public entry fun close_battle_from_oracle<CoinType>(
        arena: &mut Arena<CoinType>,
        oracle: &oracle_mock::Oracle,
        battle_id: u64,
        clock: &Clock,
    ) {
        assert!(table::contains(&arena.battles, battle_id), E_BATTLE_NOT_FOUND);
        let battle = table::borrow(&arena.battles, battle_id);
        let price_id = vector::borrow(&battle.assets, 0);
        let close_price = oracle_mock::get_price(oracle, price_id);
        close_battle<CoinType>(arena, battle_id, close_price, clock)
    }

    /// Close battle using Pyth price feed (pull oracle model).
    ///
    /// The client must update the Pyth price in the same transaction before calling this.
    public entry fun close_battle_from_pyth<CoinType>(
        arena: &mut Arena<CoinType>,
        price_info_object: &PriceInfoObject,
        battle_id: u64,
        max_age_secs: u64,
        clock: &Clock,
    ) {
        assert!(table::contains(&arena.battles, battle_id), E_BATTLE_NOT_FOUND);

        // Extract id bytes from provided price_info_object
        let info = pyth_price_info::get_price_info_from_price_info_object(price_info_object);
        let pid = pyth_price_info::get_price_identifier(&info);
        let id_bytes = price_identifier::get_bytes(&pid);

        // Read fresh close price
        let (close_price_pyth, close_expo_pyth) = oracle_pyth::get_price_no_older_than(
            price_info_object,
            clock,
            max_age_secs,
        );
        assert!(!pyth_i64::get_is_negative(&close_price_pyth), E_NEGATIVE_PYTH_PRICE);

        let now = clock::timestamp_ms(clock);

        let battle = table::borrow_mut(&mut arena.battles, battle_id);
        assert!(battle.has_pyth, E_BATTLE_NOT_PYTH);
        assert!(!battle.is_closed, E_BATTLE_CLOSED);
        assert!(now >= battle.close_time, E_TOO_EARLY_TO_CLOSE);

        // Ensure we close using the same feed id
        let expected_id_bytes = vector::borrow(&battle.assets, 0);
        assert!(bytes_eq(&id_bytes, expected_id_bytes), E_PYTH_FEED_MISMATCH);

        // For the same feed, expo should match between open and close.
        assert!(battle.open_expo_pyth == close_expo_pyth, E_PYTH_EXPO_MISMATCH);

        let open_mag = pyth_i64::get_magnitude_if_positive(&battle.open_price_pyth);
        let close_mag = pyth_i64::get_magnitude_if_positive(&close_price_pyth);

        let outcome = if (close_mag > open_mag) {
            OUTCOME_UP
        } else if (close_mag < open_mag) {
            OUTCOME_DOWN
        } else {
            OUTCOME_TIE
        };

        // Store close price (single asset for now)
        vector::push_back(&mut battle.close_prices, close_mag);

        battle.close_price_pyth = close_price_pyth;
        battle.close_expo_pyth = close_expo_pyth;
        battle.pool_at_close = balance::value(&battle.pool);
        battle.is_closed = true;
        battle.outcome = outcome;

        event::emit(BattleClosed { battle_id, close_price: close_mag, outcome });
    }

    /// Close battle (caller supplies close_price).
    ///
    /// In production, ensure the close_price is obtained from Pyth inside the same transaction
    /// (e.g. a PTB that updates/validates the Pyth price feed then calls this function).
    public entry fun close_battle<CoinType>(
        arena: &mut Arena<CoinType>,
        battle_id: u64,
        close_price: u64,
        clock: &Clock,
    ) {
        assert!(table::contains(&arena.battles, battle_id), E_BATTLE_NOT_FOUND);

        let battle = table::borrow_mut(&mut arena.battles, battle_id);
        assert!(!battle.is_closed, E_BATTLE_CLOSED);

        let now = clock::timestamp_ms(clock);
        assert!(now >= battle.close_time, E_TOO_EARLY_TO_CLOSE);

        let open_price = *vector::borrow(&battle.open_prices, 0);

        let outcome = if (close_price > open_price) {
            OUTCOME_UP
        } else if (close_price < open_price) {
            OUTCOME_DOWN
        } else {
            OUTCOME_TIE
        };

        // Store close price (single asset for now)
        vector::push_back(&mut battle.close_prices, close_price);

        battle.pool_at_close = balance::value(&battle.pool);
        battle.is_closed = true;
        battle.outcome = outcome;

        event::emit(BattleClosed { battle_id, close_price, outcome });
    }

    /// Claim reward.
    ///
    /// Payout rules:
    /// - If tie: everyone gets their stake back.
    /// - Otherwise: winners split the whole pool pro-rata by stake.
    /// - Losers get 0.
    public entry fun claim<CoinType>(
        arena: &mut Arena<CoinType>,
        battle_id: u64,
        ctx: &mut TxContext,
    ) {
        claim_impl(arena, battle_id, tx_context::sender(ctx), ctx)
    }

    #[test_only]
    public fun claim_for_testing<CoinType>(
        arena: &mut Arena<CoinType>,
        battle_id: u64,
        sender: address,
        ctx: &mut TxContext,
    ) {
        claim_impl(arena, battle_id, sender, ctx)
    }

    fun claim_impl<CoinType>(
        arena: &mut Arena<CoinType>,
        battle_id: u64,
        sender: address,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&arena.battles, battle_id), E_BATTLE_NOT_FOUND);

        let battle = table::borrow_mut(&mut arena.battles, battle_id);
        assert!(battle.is_closed, E_BATTLE_NOT_CLOSED);

        assert!(table::contains(&battle.positions, sender), E_NOT_PARTICIPANT);

        let pos = table::borrow_mut(&mut battle.positions, sender);
        assert!(!pos.claimed, E_ALREADY_CLAIMED);
        pos.claimed = true;

        let mut payout = 0u64;

        if (battle.outcome == OUTCOME_TIE) {
            payout = pos.stake;
        } else {
            let winners_total = if (battle.outcome == OUTCOME_UP) {
                battle.total_up
            } else {
                battle.total_down
            };
            assert!(winners_total > 0, E_NO_WINNERS);

            if (pos.direction == battle.outcome) {
                // pro-rata split of pool (based on close-time snapshot)
                payout = (battle.pool_at_close * pos.stake) / winners_total;
            };
        };

        if (payout > 0) {
            let payout_bal = balance::split(&mut battle.pool, payout);
            let payout_coin = coin::from_balance(payout_bal, ctx);
            transfer::public_transfer(payout_coin, sender);
        };

        event::emit(Claimed { battle_id, player: sender, payout });
    }

    /// Withdraw accumulated platform fees.
    public entry fun withdraw_fees<CoinType>(arena: &mut Arena<CoinType>, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(sender == arena.fee_recipient, E_NOT_FEE_RECIPIENT);

        let bal = balance::withdraw_all(&mut arena.fees);
        let coin = coin::from_balance(bal, ctx);
        transfer::public_transfer(coin, sender);
    }

    /// Views
    public fun fee_flat<CoinType>(arena: &Arena<CoinType>): u64 {
        arena.fee_flat
    }

    public fun battle_pool_value<CoinType>(arena: &Arena<CoinType>, battle_id: u64): u64 {
        assert!(table::contains(&arena.battles, battle_id), E_BATTLE_NOT_FOUND);
        let battle = table::borrow(&arena.battles, battle_id);
        balance::value(&battle.pool)
    }

    public fun battle_outcome<CoinType>(arena: &Arena<CoinType>, battle_id: u64): u8 {
        assert!(table::contains(&arena.battles, battle_id), E_BATTLE_NOT_FOUND);
        let battle = table::borrow(&arena.battles, battle_id);
        battle.outcome
    }
}
