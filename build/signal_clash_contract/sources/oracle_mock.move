module signal_clash::oracle_mock {
    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};

    /// Price oracle for local tests.
    ///
    /// NOTE: This is NOT secure and is only meant to unblock local development.
    /// In production, replace the read path with Pyth on-chain price reads.
    public struct Oracle has key, store {
        id: UID,
        admin: address,
        prices: Table<vector<u8>, u64>,
    }

    const E_NOT_ADMIN: u64 = 0;
    const E_PRICE_NOT_FOUND: u64 = 1;

    public fun new(admin: address, ctx: &mut TxContext): Oracle {
        Oracle {
            id: object::new(ctx),
            admin,
            prices: table::new(ctx),
        }
    }

    public fun admin(oracle: &Oracle): address {
        oracle.admin
    }

    /// Set a price for a given Pyth price id (bytes).
    public entry fun set_price(
        oracle: &mut Oracle,
        price_id: vector<u8>,
        price: u64,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == oracle.admin, E_NOT_ADMIN);
        set_price_impl(oracle, price_id, price)
    }

    #[test_only]
    /// Test helper (unit tests don't have a real native sender).
    public fun set_price_for_testing(oracle: &mut Oracle, price_id: vector<u8>, price: u64) {
        set_price_impl(oracle, price_id, price)
    }

    fun set_price_impl(oracle: &mut Oracle, price_id: vector<u8>, price: u64) {
        if (table::contains(&oracle.prices, price_id)) {
            let p = table::borrow_mut(&mut oracle.prices, price_id);
            *p = price;
        } else {
            table::add(&mut oracle.prices, price_id, price);
        };
    }

    public fun get_price(oracle: &Oracle, price_id: &vector<u8>): u64 {
        if (!table::contains(&oracle.prices, *price_id)) {
            abort E_PRICE_NOT_FOUND
        };

        *table::borrow(&oracle.prices, *price_id)
    }
}
