module signal_clash::oracle_pyth {
    use pyth::price;
    use pyth::price_info::PriceInfoObject;
    use sui::clock::Clock;

    /// Read a (fresh) Pyth price.
    ///
    /// The client must update the Pyth price feed in the SAME transaction
    /// before calling your contract ("pull oracle" pattern).
    ///
    /// Returns the raw signed price as `pyth::i64::I64` plus its exponent (`pyth::i64::I64`).
    public fun get_price_no_older_than(
        price_info_object: &PriceInfoObject,
        clock: &Clock,
        max_age_seconds: u64,
    ): (pyth::i64::I64, pyth::i64::I64) {
        let p = pyth::pyth::get_price_no_older_than(price_info_object, clock, max_age_seconds);
        (price::get_price(&p), price::get_expo(&p))
    }
}
