# M Token NTT Integration Plan (Final)

## Core Architecture: Ownership Transfer
**The NTT State object will own the MTokenGlobal and RegistrarGlobal objects directly, with TreasuryCap migrated from MTokenGlobal to NTT State, enabling full internal access without any function signature changes.**

## Architectural Changes Overview

### 1. Treasury Cap Migration
- **FROM**: `MTokenGlobal` contains `TreasuryCap<M_TOKEN>`
- **TO**: NTT `State<M_TOKEN>` contains `TreasuryCap<M_TOKEN>`
- **Reason**: Follows standard NTT pattern where State manages token minting/burning

### 2. Global Objects Ownership Transfer
- **FROM**: `MTokenGlobal` and `RegistrarGlobal` as shared objects
- **TO**: `MTokenGlobal` and `RegistrarGlobal` owned by NTT `State`
- **Benefit**: Direct internal access without function signature changes

### 3. Portal Capabilities Integration
- NTT State stores portal capabilities for protected operations
- Enables M Token and Registrar operations from within NTT functions

## Phase 1: Environment Cleanup ✅ COMPLETE
- Renamed package to `portal`
- Removed unnecessary dependencies
- Deleted wrapper files
- All packages building successfully

## Phase 2: Structural Changes

### 2.1 Modify NTT State Structure
**File**: `ntt/sources/state.move`

**Add imports for portal modules**:
```move
module ntt::state {
    use sui::coin::TreasuryCap;
    // ... existing imports ...

    // M Token imports
    use portal::m_token::{MTokenGlobal, PortalCap as MTokenPortalCap};
    use portal::registrar::{RegistrarGlobal, PortalCap as RegistrarPortalCap};
```

**Extend State struct**:
```move
public struct State<phantom T> has key, store {
    // ... existing fields unchanged ...

    // M Token extensions (owned objects)
    m_token_global: Option<MTokenGlobal>,
    registrar_global: Option<RegistrarGlobal>,
    m_token_cap: Option<MTokenPortalCap>,
    registrar_cap: Option<RegistrarPortalCap>,
}
```

**Update constructor**:
```move
public(package) fun new<CoinType>(
    chain_id: u16,
    mode: Mode,
    treasury_cap: Option<TreasuryCap<CoinType>>,
    upgrade_cap_id: ID,
    ctx: &mut TxContext
): (State<CoinType>, AdminCap) {
    // ... existing implementation ...

    let state = State {
        // ... existing fields ...

        // Initialize M Token fields as None
        m_token_global: option::none(),
        registrar_global: option::none(),
        m_token_cap: option::none(),
        registrar_cap: option::none(),
    };

    (state, admin_cap)
}
```

**Add M Token state management functions**:
```move
// Check if this is an M Token NTT
public fun has_m_token_globals<T>(state: &State<T>): bool {
    option::is_some(&state.m_token_global)
}

// Set M Token globals (called during setup)
public(package) fun set_m_token_globals<T>(
    state: &mut State<T>,
    m_token_global: MTokenGlobal,
    registrar_global: RegistrarGlobal,
    m_token_cap: MTokenPortalCap,
    registrar_cap: RegistrarPortalCap,
) {
    option::fill(&mut state.m_token_global, m_token_global);
    option::fill(&mut state.registrar_global, registrar_global);
    option::fill(&mut state.m_token_cap, m_token_cap);
    option::fill(&mut state.registrar_cap, registrar_cap);
}

// Accessor functions for internal use
public(package) fun borrow_m_token_global<T>(state: &State<T>): &MTokenGlobal {
    option::borrow(&state.m_token_global)
}

public(package) fun borrow_m_token_global_mut<T>(state: &mut State<T>): &mut MTokenGlobal {
    option::borrow_mut(&mut state.m_token_global)
}

public(package) fun borrow_registrar_global_mut<T>(state: &mut State<T>): &mut RegistrarGlobal {
    option::borrow_mut(&mut state.registrar_global)
}

public(package) fun borrow_m_token_cap<T>(state: &State<T>): &MTokenPortalCap {
    option::borrow(&state.m_token_cap)
}

public(package) fun borrow_registrar_cap<T>(state: &State<T>): &RegistrarPortalCap {
    option::borrow(&state.registrar_cap)
}
```

### 2.2 Modify MTokenGlobal Structure
**File**: `portal/sources/token/m_token.move`

**Remove TreasuryCap from MTokenGlobal**:
```move
public struct MTokenGlobal has key, store {  // Note: now has 'store' ability
    id: UID,
    // treasury_cap: TreasuryCap<M_TOKEN>, // ← REMOVE THIS FIELD
    continuous_indexing: ContinuousIndexing,
    earners: Table<address, EarnerSnapshot>,
    total_earner_balance: u256,
    principal_of_total_earner_balance: u256,
    is_earner_list_ignored: bool,
    earners_list_hash: vector<u8>,
    // ... other fields remain unchanged
}
```

**Update all M Token functions to accept TreasuryCap parameter**:
```move
// OLD: Treasury cap accessed from global
public fun mint(
    global: &mut MTokenGlobal,
    cap: &PortalCap,
    recipient: address,
    amount: u256,
    index: u128,
    ctx: &mut TxContext
) {
    let treasury_cap = &global.treasury_cap; // ← OLD WAY
    // ...
}

// NEW: Treasury cap passed as parameter
public fun mint_with_treasury_cap(
    global: &mut MTokenGlobal,
    treasury_cap: &mut TreasuryCap<M_TOKEN>,
    cap: &PortalCap,
    recipient: address,
    amount: u256,
    index: u128,
    ctx: &mut TxContext
) {
    // Use treasury_cap parameter directly
    // ...
}

// Wrapper function to maintain compatibility for existing callers
public fun mint(
    global: &mut MTokenGlobal,
    treasury_cap: &mut TreasuryCap<M_TOKEN>,
    cap: &PortalCap,
    recipient: address,
    amount: u256,
    index: u128,
    ctx: &mut TxContext
) {
    mint_with_treasury_cap(global, treasury_cap, cap, recipient, amount, index, ctx)
}
```

**Update initialization function**:
```move
public fun create_global_and_treasury(
    witness: M_TOKEN,
    decimals: u8,
    symbol: vector<u8>,
    name: vector<u8>,
    description: vector<u8>,
    icon_url: Option<Url>,
    ctx: &mut TxContext
): (MTokenGlobal, TreasuryCap<M_TOKEN>) {  // ← Return both separately
    let treasury_cap = coin::create_currency(
        witness, decimals, symbol, name, description, icon_url, ctx
    );

    let global = MTokenGlobal {
        id: object::new(ctx),
        // treasury_cap removed from here
        continuous_indexing: continuous_indexing::new(ctx),
        earners: table::new(ctx),
        total_earner_balance: 0,
        principal_of_total_earner_balance: 0,
        is_earner_list_ignored: false,
        earners_list_hash: vector::empty(),
    };

    (global, treasury_cap)  // Return separately
}
```

## Phase 3: NTT Function Integration

### 3.1 Update Release Function
**File**: `ntt/sources/ntt.move`

**Add imports for portal modules**:
```move
module ntt::ntt {
    // ... existing imports ...
    use portal::m_token;
    use portal::registrar;
    use portal::payload_encoder;
```

**Modify existing release function** (signature unchanged):
```move
public fun release<CoinType>(
    state: &mut State<CoinType>,
    version_gated: VersionGated,
    from_chain_id: u16,
    message: NttManagerMessage<NativeTokenTransfer>,
    coin_meta: &CoinMetadata<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    if (state::has_m_token_globals(state)) {
        // M Token path - handle internally
        release_m_token_internal(
            state, version_gated, from_chain_id,
            message, coin_meta, clock, ctx
        );
    } else {
        // Standard NTT path (unchanged)
        let (recipient, coins, _payload) = release_impl(
            state, version_gated, from_chain_id,
            message, coin_meta, clock, ctx
        );
        transfer::public_transfer(coins, recipient)
    }
}
```

**Add internal M Token release logic**:
```move
fun release_m_token_internal<CoinType>(
    state: &mut State<CoinType>,
    version_gated: VersionGated,
    from_chain_id: u16,
    message: NttManagerMessage<NativeTokenTransfer>,
    coin_meta: &CoinMetadata<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let (recipient, coins, payload) = release_impl(
        state, version_gated, from_chain_id,
        message, coin_meta, clock, ctx
    );

    // Process M Token payload
    if (option::is_some(&payload)) {
        let payload_bytes = option::destroy_some(payload);

        // Check for custom M operations (M0IT/M0KT/M0LU)
        if (process_m_custom_payload(state, payload_bytes, ctx)) {
            // Custom operation handled, no token transfer
            coin::destroy_zero(coins);
            return
        };

        // Regular M Token transfer with index
        let (index, _dest_token) = payload_encoder::decode_m_additional_payload(&payload_bytes);

        // Destroy NTT coins and mint M Tokens with proper index
        let amount = coin::value(&coins);
        coin::destroy_zero(coins);

        mint_m_token_with_index(state, recipient, amount, index, ctx);
    } else {
        // Standard token transfer without payload
        transfer::public_transfer(coins, recipient)
    }
}
```

**Add M Token helper functions**:
```move
// Process custom M payload types (M0IT/M0KT/M0LU)
fun process_m_custom_payload<T>(
    state: &mut State<T>,
    payload: vector<u8>,
    ctx: &mut TxContext
): bool {
    if (vector::length(&payload) < 4) return false;

    let payload_type = payload_encoder::get_payload_type(&payload);

    if (payload_encoder::is_index_payload(&payload_type)) {
        // M0IT - Index Transfer
        let (index, _chain_id) = payload_encoder::decode_index_payload(payload);
        let m_token_global = state::borrow_m_token_global_mut(state);
        let m_token_cap = state::borrow_m_token_cap(state);

        m_token::update_index(m_token_global, m_token_cap, index, ctx);
        true
    } else if (payload_encoder::is_key_payload(&payload_type)) {
        // M0KT - Key Transfer
        let (key, value, _chain_id) = payload_encoder::decode_key_payload(payload);
        let registrar_global = state::borrow_registrar_global_mut(state);
        let registrar_cap = state::borrow_registrar_cap(state);

        registrar::set_key(registrar_global, registrar_cap, key, value);
        true
    } else if (payload_encoder::is_list_payload(&payload_type)) {
        // M0LU - List Update
        let (list_name, account, add, _chain_id) =
            payload_encoder::decode_list_update_payload(payload);
        let registrar_global = state::borrow_registrar_global_mut(state);
        let registrar_cap = state::borrow_registrar_cap(state);

        if (add) {
            registrar::add_to_list(registrar_global, registrar_cap, list_name, account);
        } else {
            registrar::remove_from_list(registrar_global, registrar_cap, list_name, account);
        };
        true
    } else {
        false // Not a custom M payload
    }
}

// Mint M Tokens with index update using NTT's treasury cap
fun mint_m_token_with_index<T>(
    state: &mut State<T>,
    recipient: address,
    amount: u64,
    index: u128,
    ctx: &mut TxContext
) {
    let m_token_global = state::borrow_m_token_global_mut(state);
    let m_token_cap = state::borrow_m_token_cap(state);
    let treasury_cap = state::borrow_treasury_cap_mut(state); // From NTT State

    let current_index = m_token::current_index(m_token_global);

    if (index > current_index) {
        // Mint with index update
        m_token::mint(
            m_token_global,
            treasury_cap,
            m_token_cap,
            recipient,
            (amount as u256),
            index,
            ctx
        );
    } else {
        // Mint without index update
        m_token::mint_no_index(
            m_token_global,
            treasury_cap,
            m_token_cap,
            recipient,
            (amount as u256),
            ctx
        );
    }
}
```

### 3.2 Update Transfer Functions
**Add M Token index to outbound transfers**:
```move
public fun prepare_transfer<CoinType>(
    state: &State<CoinType>,
    mut coins: Coin<CoinType>,
    coin_meta: &CoinMetadata<CoinType>,
    recipient_chain: u16,
    recipient: vector<u8>,
    payload: Option<vector<u8>>,
    should_queue: bool,
): (TransferTicket<CoinType>, Balance<CoinType>) {
    // Auto-add M Token index if no custom payload provided
    let final_payload = if (state::has_m_token_globals(state) && option::is_none(&payload)) {
        let m_token_global = state::borrow_m_token_global(state);
        let current_index = m_token::current_index(m_token_global);
        // TODO: Derive destination token address from recipient_chain
        let destination_token = vector::empty<u8>();

        option::some(payload_encoder::encode_m_additional_payload(
            current_index,
            destination_token
        ))
    } else {
        payload
    };

    // Continue with standard NTT prepare_transfer logic
    let from_decimals = coin_meta.get_decimals();
    let peer = state.borrow_peer(recipient_chain);
    let to_decimals = peer.get_token_decimals();
    let recipient_manager = *peer.borrow_address();
    let (trimmed_amount, dust) =
        trimmed_amount::remove_dust(&mut coins, from_decimals, to_decimals);

    let ticket = TransferTicket {
        coins,
        token_address: wormhole::external_address::from_id(object::id(coin_meta)),
        trimmed_amount,
        recipient_chain,
        recipient: external_address::new(bytes32::new(recipient)),
        payload: final_payload, // Use final_payload with M Token index
        recipient_manager,
        should_queue,
    };

    (ticket, dust)
}
```

## Phase 4: Portal Setup Module

### 4.1 Create Setup Module
**File**: `portal/sources/setup.move`
```move
module portal::setup {
    use ntt::state::{Self, State, AdminCap};
    use ntt::mode;
    use portal::m_token::{Self, M_TOKEN, MTokenGlobal};
    use portal::registrar::{Self, RegistrarGlobal};

    /// Initialize M Token NTT by transferring ownership of globals to NTT State
    /// This replaces the need for separate M Token and NTT initialization
    public fun initialize_m_ntt(
        m_token_global: MTokenGlobal,
        registrar_global: RegistrarGlobal,
        chain_id: u16,
        treasury_cap: TreasuryCap<M_TOKEN>,  // Passed to NTT State
        upgrade_cap_id: ID,
        ctx: &mut TxContext
    ): (State<M_TOKEN>, AdminCap) {
        // Create portal capabilities
        let m_token_cap = m_token::create_portal_cap(ctx);
        let registrar_cap = registrar::create_portal_cap(ctx);

        // Create NTT state with treasury cap
        let (mut state, admin_cap) = state::new(
            chain_id,
            mode::BURNING, // M Token is always BURNING mode
            option::some(treasury_cap), // Treasury cap goes to NTT State
            upgrade_cap_id,
            ctx
        );

        // Transfer ownership of M Token globals to NTT state
        state::set_m_token_globals(
            &mut state,
            m_token_global,
            registrar_global,
            m_token_cap,
            registrar_cap
        );

        (state, admin_cap)
    }

    /// Helper to create both globals and initialize NTT in one call
    public fun create_and_initialize_m_ntt(
        witness: M_TOKEN,
        decimals: u8,
        symbol: vector<u8>,
        name: vector<u8>,
        description: vector<u8>,
        icon_url: Option<Url>,
        chain_id: u16,
        upgrade_cap_id: ID,
        ctx: &mut TxContext
    ): (State<M_TOKEN>, AdminCap) {
        // Create globals separately (treasury cap separate from global)
        let (m_token_global, treasury_cap) = m_token::create_global_and_treasury(
            witness, decimals, symbol, name, description, icon_url, ctx
        );
        let registrar_global = registrar::create_global(ctx);

        // Initialize M Token NTT
        initialize_m_ntt(
            m_token_global,
            registrar_global,
            chain_id,
            treasury_cap,
            upgrade_cap_id,
            ctx
        )
    }
}
```

## Phase 5: Migration and Compatibility

### 5.1 Registrar Global Updates
**File**: `portal/sources/ttg/registrar.move`

**Ensure RegistrarGlobal has 'store' ability**:
```move
public struct RegistrarGlobal has key, store {  // Add 'store' ability
    id: UID,
    keys: Table<vector<u8>, vector<u8>>,
    lists: Table<vector<u8>, VecSet<address>>,
}
```

### 5.2 Error Handling
**Add error constants to NTT**:
```move
module ntt::ntt {
    // ... existing imports ...

    #[error]
    const ENotMTokenNTT: vector<u8> = b"Operation requires M Token NTT";

    #[error]
    const EMTokenGlobalsNotSet: vector<u8> = b"M Token globals not set in state";
}
```

## Implementation Timeline

### Week 1: Core Structural Changes
- [ ] Modify NTT State structure
- [ ] Update MTokenGlobal (remove treasury cap)
- [ ] Create setup module
- [ ] Update RegistrarGlobal (add store ability)

### Week 2: NTT Function Integration
- [ ] Implement M Token detection in release
- [ ] Add internal M Token processing functions
- [ ] Update prepare_transfer for auto-index
- [ ] Implement custom payload processing

### Week 3: Testing and Validation
- [ ] Test standard NTT operations (unchanged)
- [ ] Test M Token operations through standard NTT interface
- [ ] Validate custom payload processing (M0IT/M0KT/M0LU)
- [ ] Test treasury cap migration

### Week 4: PTB Integration and Documentation
- [ ] Update PTBs to use setup module for initialization
- [ ] Verify existing PTBs work unchanged for standard operations
- [ ] Performance testing and optimization
- [ ] Final integration testing

## Success Criteria

1. ✅ **Zero Breaking Changes**: All existing NTT function signatures unchanged
2. ✅ **Treasury Migration**: TreasuryCap properly moved from MTokenGlobal to NTT State
3. ✅ **Ownership Transfer**: MTokenGlobal and RegistrarGlobal owned by NTT State
4. ✅ **Internal Processing**: All M Token logic handled within existing functions
5. ✅ **Custom Payload Support**: M0IT/M0KT/M0LU messages processed internally
6. ✅ **PTB Compatibility**: Existing PTBs work unchanged
7. ✅ **Performance**: No degradation for standard NTT operations

## Critical Implementation Notes

1. **Treasury Cap Flow**:
   - MTokenGlobal creation returns (MTokenGlobal, TreasuryCap) separately
   - TreasuryCap goes to NTT State during initialization
   - All M Token mint functions accept TreasuryCap as parameter

2. **Ownership Model**:
   - MTokenGlobal and RegistrarGlobal must have `store` ability
   - Objects are owned by NTT State, not shared globally
   - Portal capabilities stored alongside for protected operations

3. **Backward Compatibility**:
   - Standard NTT operations remain completely unchanged
   - M Token detection happens internally via optional fields
   - PTBs use same function calls, M Token logic happens transparently

This architecture provides complete M Token functionality while maintaining perfect compatibility with existing NTT interfaces and PTBs.

## Key Insights from EVM Portal Analysis

### Hub-Spoke Architecture Understanding
- **Ethereum Hub Portal**: Uses `LOCKING` mode, locks M tokens and sends `NativeTokenTransfer` messages
- **Sui Spoke Portal**: Uses `BURNING` mode, burns/mints M tokens based on Hub messages
- **Custom Payloads**: Three types beyond standard transfers:
  1. `M0IT` (Index Transfer): Updates M token index on remote chains
  2. `M0KT` (Key Transfer): Propagates Registrar keys to remote chains
  3. `M0LU` (List Update): Updates Registrar lists on remote chains

### EVM Portal Pattern Replication
The EVM Portal design extends NTTManager by:
1. **Inheriting from NttManagerNoRateLimiting**: Gets all standard NTT functionality
2. **Overriding `_handleMsg`**: Detects payload type and routes to appropriate handler
3. **Custom payload handlers**: `_receiveCustomPayload()` processes M0IT/M0KT/M0LU messages
4. **M Token operations**: `_mintOrUnlock()` and `_burnOrLock()` with index awareness

### Sui Move Adaptation Strategy
Since Sui doesn't support inheritance, we use **composition over inheritance**:
1. **State Ownership**: NTT State owns M Token globals (MTokenGlobal, RegistrarGlobal)
2. **Capability Pattern**: Portal capabilities enable protected operations
3. **Internal Detection**: NTT functions detect M Token presence via optional fields
4. **Zero Breaking Changes**: All existing NTT function signatures remain unchanged