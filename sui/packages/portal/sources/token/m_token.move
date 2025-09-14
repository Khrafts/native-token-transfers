module portal::m_token {
    use sui::coin::{Self};

    // ============ Constants ============

    /// Token decimals (6 decimals like in Solidity)
    const DECIMALS: u8 = 6;

    /// Token name
    const NAME: vector<u8> = b"M by M0";

    /// Token symbol
    const SYMBOL: vector<u8> = b"M";

    /// Token description
    const DESCRIPTION: vector<u8> = b"M Token - Yield-bearing stablecoin on Sui";

    // ============ Structs ============

    /// MToken coin type witness - standard Sui coin
    public struct M_TOKEN has drop {}

    // ============ Init Function ============

    /// Initialize the M_TOKEN coin
    fun init(witness: M_TOKEN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            DECIMALS,
            SYMBOL,
            NAME,
            DESCRIPTION,
            option::none(), // no icon URL for now
            ctx
        );

        // Transfer treasury cap to deployer (will be transferred to NTT later)
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));

        // Freeze the metadata to make it immutable
        transfer::public_freeze_object(metadata);
    }

    // ============ Getters ============

    /// Get token decimals
    public fun get_decimals(): u8 {
        DECIMALS
    }

    /// Get token name
    public fun get_name(): vector<u8> {
        NAME
    }

    /// Get token symbol
    public fun get_symbol(): vector<u8> {
        SYMBOL
    }
}