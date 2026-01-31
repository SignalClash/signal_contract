#[test_only]
module signal_clash::signal_clash_tests {
    use sui::clock;
    use sui::coin;
    use sui::transfer;
    use sui::tx_context;

    use signal_clash::mock_usdt::USDT;
    use signal_clash::oracle_mock;
    use signal_clash::signal_clash;

    #[test]
    fun test_up_side_wins_and_claims_pool() {
        let mut ctx_admin = tx_context::dummy();
        let mut ctx_p1 = tx_context::dummy();
        let mut ctx_p2 = tx_context::dummy();

        let mut clk = clock::create_for_testing(&mut ctx_admin);
        clock::set_for_testing(&mut clk, 1000);

        let mut oracle = oracle_mock::new(@0xA, &mut ctx_admin);
        let price_id = b"BTC";
        oracle_mock::set_price_for_testing(&mut oracle, price_id, 100);

        // fee_flat = 5 (pretend 5 USDT in smallest units for the test)
        let mut arena = signal_clash::new_arena<USDT>(5, @0xFEE, &mut ctx_admin);

        signal_clash::create_battle_from_oracle<USDT>(
            &mut arena,
            &oracle,
            price_id,
            1000,
            2000,
            &clk,
            &mut ctx_admin,
        );

        // p1 bets UP with 100 (net 95)
        let stake1 = coin::mint_for_testing<USDT>(100, &mut ctx_p1);
        signal_clash::join_battle_for_testing<USDT>(&mut arena, 0, stake1, 1, @0xB, &clk, &mut ctx_p1);

        // p2 bets DOWN with 200 (net 195)
        let stake2 = coin::mint_for_testing<USDT>(200, &mut ctx_p2);
        signal_clash::join_battle_for_testing<USDT>(&mut arena, 0, stake2, 0, @0xC, &clk, &mut ctx_p2);

        // close: price goes up
        clock::set_for_testing(&mut clk, 2000);
        oracle_mock::set_price_for_testing(&mut oracle, b"BTC", 110);
        signal_clash::close_battle_from_oracle<USDT>(&mut arena, &oracle, 0, &clk);

        // p1 claims: should drain the pool (only winner)
        signal_clash::claim_for_testing<USDT>(&mut arena, 0, @0xB, &mut ctx_p1);
        assert!(signal_clash::battle_pool_value<USDT>(&arena, 0) == 0, 0);

        // p2 claims: payout 0, pool stays 0
        signal_clash::claim_for_testing<USDT>(&mut arena, 0, @0xC, &mut ctx_p2);
        assert!(signal_clash::battle_pool_value<USDT>(&arena, 0) == 0, 1);

        assert!(signal_clash::battle_outcome<USDT>(&arena, 0) == 1, 2);

        // Consume non-drop values to satisfy the Move test harness.
        transfer::public_transfer(arena, @0xA);
        transfer::public_transfer(oracle, @0xA);
        clock::destroy_for_testing(clk);
    }
}
