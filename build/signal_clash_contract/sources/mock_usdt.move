module signal_clash::mock_usdt {
    /// Placeholder coin type used for local tests / development.
    ///
    /// In production you will likely use the real USDT type on Sui instead.
    public struct USDT has store, drop {}
}
