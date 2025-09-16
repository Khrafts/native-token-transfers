module ntt::ntt {
    use wormhole::external_address::{Self, ExternalAddress};
    use wormhole::bytes32;
    use sui::balance::Balance;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin, CoinMetadata};
    use sui::transfer;
    use ntt_common::trimmed_amount::{Self, TrimmedAmount};
    use ntt::state::{Self, State};
    use ntt::outbox::{Self, OutboxKey};
    use ntt_common::native_token_transfer::{Self, NativeTokenTransfer};
    use ntt_common::ntt_manager_message::{Self, NttManagerMessage};
    use ntt_common::validated_transceiver_message::ValidatedTransceiverMessage;
    use ntt::upgrades::VersionGated;
    use std::bcs;

    // Direct M Token integration - embedded payload encoding
    use sui::address;

    // M Token integration - direct implementation without portal dependencies

    #[error]
    const ETransferExceedsRateLimit: vector<u8>
        = b"Transfer exceeds rate limit";

    #[error]
    const ECantReleaseYet: vector<u8>
        = b"Can't release yet";

    #[error]
    const EWrongDestinationChain: vector<u8>
        = b"Wrong destination chain";

    #[allow(lint(coin_field))]
    public struct TransferTicket<phantom CoinType> {
        coins: Coin<CoinType>,
        token_address: ExternalAddress,
        trimmed_amount: TrimmedAmount,
        recipient_chain: u16,
        recipient: ExternalAddress,
        payload: Option<vector<u8>>,
        recipient_manager: ExternalAddress,
        should_queue: bool,
    }

    #[test_only]
    /// Create a transfer ticket for testing purposes
    public fun new_transfer_ticket<CoinType>(
        coins: Coin<CoinType>,
        token_address: ExternalAddress,
        trimmed_amount: TrimmedAmount,
        recipient_chain: u16,
        recipient: ExternalAddress,
        payload: Option<vector<u8>>,
        recipient_manager: ExternalAddress,
        should_queue: bool
    ): TransferTicket<CoinType> {
        TransferTicket {
            coins,
            token_address,
            trimmed_amount,
            recipient_chain,
            recipient,
            payload,
            recipient_manager,
            should_queue
        }
    }

    // upgrade safe
    public fun prepare_transfer<CoinType>(
        state: &State<CoinType>,
        mut coins: Coin<CoinType>,
        coin_meta: &CoinMetadata<CoinType>,
        recipient_chain: u16,
        recipient: vector<u8>,
        payload: Option<vector<u8>>,
        should_queue: bool,
    ): (
        TransferTicket<CoinType>,
        Balance<CoinType> // dust (TODO: should we create a coin for it?)
    ) {
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
            payload,
            recipient_manager,
            should_queue,
        };

        (ticket, dust)
    }

    public fun transfer_tx_sender<CoinType>(
        state: &mut State<CoinType>,
        version_gated: VersionGated,
        coin_meta: &CoinMetadata<CoinType>,
        ticket: TransferTicket<CoinType>,
        clock: &Clock,
        ctx: &TxContext
    ): OutboxKey {
        transfer_impl(state, version_gated, coin_meta, ticket, clock, ctx.sender())
    }

    public fun transfer_with_auth<CoinType, Auth>(
        auth: &Auth,
        state: &mut State<CoinType>,
        version_gated: VersionGated,
        coin_meta: &CoinMetadata<CoinType>,
        ticket: TransferTicket<CoinType>,
        clock: &Clock,
    ): OutboxKey {
        transfer_impl(state, version_gated, coin_meta, ticket, clock, ntt_common::contract_auth::assert_auth_type(auth, b"NttSenderAuth"))
    }

    fun transfer_impl<CoinType>(
        state: &mut State<CoinType>,
        version_gated: VersionGated,
        coin_meta: &CoinMetadata<CoinType>,
        ticket: TransferTicket<CoinType>,
        clock: &Clock,
        sender: address
    ): OutboxKey {
        version_gated.check_version(state);

        state.assert_not_paused();

        let TransferTicket {
            coins,
            token_address,
            trimmed_amount,
            recipient_chain,
            recipient,
            payload,
            recipient_manager,
            should_queue
        } = ticket;

        if (state.borrow_mode().is_locking()) {
            coin::put(state.borrow_balance_mut(), coins);
        } else {
            coin::burn(state.borrow_treasury_cap_mut(), coins);
        };

        let consumed_or_delayed
            = state.borrow_outbox_mut()
                   .borrow_rate_limit_mut()
                   .consume_or_delay(clock, trimmed_amount.untrim(coin_meta.get_decimals()));

        let release_timestamp = if (consumed_or_delayed.is_delayed()) {
            let release_timestamp = consumed_or_delayed.delayed_until();
            if (!should_queue) {
                abort ETransferExceedsRateLimit
            };
            release_timestamp
        } else {
            // consumed. refill inbox rate limit
            state.borrow_peer_mut(recipient_chain)
                 .borrow_inbound_rate_limit_mut()
                 .refill(clock, trimmed_amount.amount());
            clock.timestamp_ms()
        };

        let message_id = state.next_message_id();

        state.borrow_outbox_mut().add(
            outbox::new_outbox_item(
                release_timestamp,
                recipient_manager,
                ntt_manager_message::new(
                    message_id,
                    external_address::from_address(sender),
                    native_token_transfer::new(
                        trimmed_amount,
                        token_address,
                        recipient,
                        recipient_chain,
                        payload
                    )
                )
            )
        )
    }

    public fun redeem<CoinType, Transceiver>(
        state: &mut State<CoinType>,
        version_gated: VersionGated,
        coin_meta: &CoinMetadata<CoinType>,
        validated_message: ValidatedTransceiverMessage<Transceiver, vector<u8>>,
        clock: &Clock,
    ) {
        version_gated.check_version(state);

        state.assert_not_paused();

        let (chain_id, source_ntt_manager, ntt_manager_message) =
            validated_message.destruct_recipient_only(&ntt::auth::new_auth(), state);

        let ntt_manager_message = ntt_common::ntt_manager_message::map!(ntt_manager_message, |buf| {
            native_token_transfer::parse(buf)
        });

        assert!(source_ntt_manager == state.borrow_peer(chain_id).borrow_address());

        // NOTE: this checks that the transceiver is in fact registered
        state.vote<Transceiver, _>(chain_id, ntt_manager_message);

        let (_id, _sender, payload) = ntt_manager_message.destruct();
        let (trimmed_amount, _source_token, _recipient, to_chain, _payload) = payload.destruct();
        assert!(to_chain == state.get_chain_id(), EWrongDestinationChain);

        let amount = trimmed_amount.untrim(coin_meta.get_decimals());

        let inbox_item = state.borrow_inbox_item_mut(chain_id, ntt_manager_message);
        let num_votes = inbox_item.count_enabled_votes(&state.get_enabled_transceivers());
        if (num_votes < state.get_threshold()) {
            return
        };

        // TODO: should this last part be a separate function? so attestation handling, THEN this

        let consumed_or_delayed
            = state.borrow_peer_mut(chain_id)
                   .borrow_inbound_rate_limit_mut()
                   .consume_or_delay(clock, amount);

        let release_timestamp = if (consumed_or_delayed.is_delayed()) {
            consumed_or_delayed.delayed_until()
        } else {
            // consumed. refill outbox rate limit
            state.borrow_outbox_mut()
                .borrow_rate_limit_mut()
                .refill(clock, amount);
            clock.timestamp_ms()
        };

        let inbox_item = state.borrow_inbox_item_mut(chain_id, ntt_manager_message);
        inbox_item.release_after(release_timestamp)
    }

    public fun release<CoinType>(
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

        // NOTE: payload handling must be done by modifying the implementation here.
        // the default NTT implementation simply ignores the payload

        if (state.has_m_token_globals() && option::is_some(&payload)) {
            // M Token path - handle custom payloads directly
            handle_m_token_payload(state, recipient, coins, option::destroy_some(payload), ctx);
        } else {
            // Standard NTT path - transfer coins normally
            transfer::public_transfer(coins, recipient)
        }
    }

    fun release_impl<CoinType>(
        state: &mut State<CoinType>,
        version_gated: VersionGated,
        chain_id: u16,
        message: NttManagerMessage<NativeTokenTransfer>,
        coin_meta: &CoinMetadata<CoinType>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (address, Coin<CoinType>, Option<vector<u8>>) {

        version_gated.check_version(state);

        state.assert_not_paused();

        // NOTE: this validates that the message has enough votes etc
        let released = state.try_release_in(chain_id, message, clock);

        if (!released) {
            abort ECantReleaseYet
        };

        let (_, _, payload) = message.destruct();

        // TODO: to_chain is verified when inserting into the inbox in `redeem`.
        // should we verify it here too?
        let (trimmed_amount, _source_token, recipient, _to_chain, payload) = payload.destruct();

        let amount = trimmed_amount.untrim(coin_meta.get_decimals());

        (recipient.to_address(), mint_or_unlock(state, amount, ctx), payload)
    }

    fun mint_or_unlock<CoinType>(
        state: &mut State<CoinType>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<CoinType> {
        if (state.borrow_mode().is_locking()) {
            coin::take(state.borrow_balance_mut(), amount, ctx)
        } else {
            coin::mint(state.borrow_treasury_cap_mut(), amount, ctx)
        }
    }

    // ============ M Token Payload Handling ============

    /// Handle M Token payloads directly in NTT as intended by original design
    fun handle_m_token_payload<CoinType>(
        state: &mut State<CoinType>,
        recipient: address,
        coins: Coin<CoinType>,
        payload: vector<u8>,
        ctx: &mut TxContext
    ) {
        if (vector::length(&payload) < 4) {
            // Invalid payload, transfer coins normally
            transfer::public_transfer(coins, recipient);
            return
        };

        let payload_type = get_payload_type(&payload);

        if (is_index_payload(&payload_type)) {
            // M0IT - Index Transfer (no token transfer)
            handle_index_transfer(state, payload, ctx);
            coin::destroy_zero(coins);
        } else if (is_key_payload(&payload_type)) {
            // M0KT - Key Transfer (no token transfer)
            handle_key_transfer(state, payload, ctx);
            coin::destroy_zero(coins);
        } else if (is_list_payload(&payload_type)) {
            // M0LU - List Update (no token transfer)
            handle_list_update(state, payload, ctx);
            coin::destroy_zero(coins);
        } else {
            // Regular M Token transfer with index
            handle_token_transfer_with_index(state, recipient, coins, payload, ctx);
        }
    }

    /// Handle M0IT - Index Transfer payload
    fun handle_index_transfer<CoinType>(
        state: &mut State<CoinType>,
        payload: vector<u8>,
        ctx: &mut TxContext
    ) {
        let (index, _chain_id) = decode_index_payload(payload);
        update_m_token_index(state, index, ctx);
    }

    /// Handle M0KT - Key Transfer payload
    fun handle_key_transfer<CoinType>(
        state: &mut State<CoinType>,
        payload: vector<u8>,
        ctx: &mut TxContext
    ) {
        let (key, value, _chain_id) = decode_key_payload(payload);
        set_registrar_key(state, key, value, ctx);
    }

    /// Handle M0LU - List Update payload
    fun handle_list_update<CoinType>(
        state: &mut State<CoinType>,
        payload: vector<u8>,
        ctx: &mut TxContext
    ) {
        let (list_name, account, add, _chain_id) = decode_list_update_payload(payload);
        if (add) {
            add_to_registrar_list(state, list_name, account, ctx);
        } else {
            remove_from_registrar_list(state, list_name, account, ctx);
        };
    }

    /// Handle regular M Token transfer with index
    fun handle_token_transfer_with_index<CoinType>(
        state: &mut State<CoinType>,
        recipient: address,
        coins: Coin<CoinType>,
        payload: vector<u8>,
        ctx: &mut TxContext
    ) {
        let (index, _dest_token) = decode_m_additional_payload(&payload);
        let amount = coin::value(&coins);
        coin::destroy_zero(coins);
        mint_m_token_with_index(state, recipient, amount, index, ctx);
      }

    // ============ Embedded Payload Encoding Functions ============

    // Payload type constants
    const TOKEN_TYPE: u8 = 0;
    const INDEX_TYPE: u8 = 1;
    const KEY_TYPE: u8 = 2;
    const LIST_TYPE: u8 = 3;

    // Payload prefixes (matching Solidity implementation)
    const INDEX_TRANSFER_PREFIX: vector<u8> = b"M0IT"; // M0 Index Transfer
    const KEY_TRANSFER_PREFIX: vector<u8> = b"M0KT";   // M0 Key Transfer
    const LIST_UPDATE_PREFIX: vector<u8> = b"M0LU";   // M0 List Update
    const NTT_PREFIX: vector<u8> = b"NTT\x00";        // Standard NTT prefix

    const PAYLOAD_PREFIX_LENGTH: u64 = 4;
    const E_INVALID_PAYLOAD_LENGTH: u64 = 1;
    const E_INVALID_PAYLOAD_PREFIX: u64 = 2;

    /// Payload type enumeration
    public struct PayloadType has store, copy, drop {
        value: u8
    }

    // ================ Payload Type Functions ================

    fun token_payload_type(): PayloadType {
        PayloadType { value: TOKEN_TYPE }
    }

    fun index_payload_type(): PayloadType {
        PayloadType { value: INDEX_TYPE }
    }

    fun key_payload_type(): PayloadType {
        PayloadType { value: KEY_TYPE }
    }

    fun list_payload_type(): PayloadType {
        PayloadType { value: LIST_TYPE }
    }

    fun is_token_payload(payload_type: &PayloadType): bool {
        payload_type.value == TOKEN_TYPE
    }

    fun is_index_payload(payload_type: &PayloadType): bool {
        payload_type.value == INDEX_TYPE
    }

    fun is_key_payload(payload_type: &PayloadType): bool {
        payload_type.value == KEY_TYPE
    }

    fun is_list_payload(payload_type: &PayloadType): bool {
        payload_type.value == LIST_TYPE
    }

    // ================ Payload Type Detection ================

    /// Determine payload type from payload bytes
    fun get_payload_type(payload: &vector<u8>): PayloadType {
        assert!(vector::length(payload) >= PAYLOAD_PREFIX_LENGTH, E_INVALID_PAYLOAD_LENGTH);

        let prefix = extract_prefix(payload);

        if (prefix == NTT_PREFIX) {
            token_payload_type()
        } else if (prefix == INDEX_TRANSFER_PREFIX) {
            index_payload_type()
        } else if (prefix == KEY_TRANSFER_PREFIX) {
            key_payload_type()
        } else if (prefix == LIST_UPDATE_PREFIX) {
            list_payload_type()
        } else {
            abort E_INVALID_PAYLOAD_PREFIX
        }
    }

    fun extract_prefix(payload: &vector<u8>): vector<u8> {
        let mut prefix = vector::empty<u8>();
        let mut i = 0;
        while (i < PAYLOAD_PREFIX_LENGTH) {
            vector::push_back(&mut prefix, *vector::borrow(payload, i));
            i = i + 1;
        };
        prefix
    }

    // ================ M Token Additional Payload ================

    /// Decode M Token additional payload
    fun decode_m_additional_payload(payload: &vector<u8>): (u128, vector<u8>) {
        assert!(vector::length(payload) >= 8 + 32, E_INVALID_PAYLOAD_LENGTH);

        let mut offset = 0;
        let (index_u64, new_offset) = read_u64(payload, offset);
        offset = new_offset;

        let destination_token = read_bytes(payload, offset, 32);

        ((index_u64 as u128), destination_token)
    }

    // ================ Index Payload ================

    /// Decode M Token index payload
    fun decode_index_payload(payload: vector<u8>): (u128, u16) {
        assert!(vector::length(&payload) >= PAYLOAD_PREFIX_LENGTH + 8 + 2, E_INVALID_PAYLOAD_LENGTH);

        let mut offset = PAYLOAD_PREFIX_LENGTH;
        let (index_u64, new_offset) = read_u64(&payload, offset);
        offset = new_offset;

        let (destination_chain_id, _) = read_u16(&payload, offset);

        ((index_u64 as u128), destination_chain_id)
    }

    // ================ Key Payload ================

    /// Decode Registrar key payload
    fun decode_key_payload(payload: vector<u8>): (vector<u8>, vector<u8>, u16) {
        assert!(vector::length(&payload) >= PAYLOAD_PREFIX_LENGTH + 32 + 32 + 2, E_INVALID_PAYLOAD_LENGTH);

        let mut offset = PAYLOAD_PREFIX_LENGTH;

        let key = read_bytes(&payload, offset, 32);
        offset = offset + 32;

        let value = read_bytes(&payload, offset, 32);
        offset = offset + 32;

        let (destination_chain_id, _) = read_u16(&payload, offset);

        (key, value, destination_chain_id)
    }

    // ================ List Update Payload ================

    /// Decode Registrar list update payload
    fun decode_list_update_payload(payload: vector<u8>): (vector<u8>, address, bool, u16) {
        assert!(vector::length(&payload) >= PAYLOAD_PREFIX_LENGTH + 32 + 32 + 1 + 2, E_INVALID_PAYLOAD_LENGTH);

        let mut offset = PAYLOAD_PREFIX_LENGTH;

        let list_name = read_bytes(&payload, offset, 32);
        offset = offset + 32;

        let account_bytes = read_bytes(&payload, offset, 32);
        let account = bytes_to_address(account_bytes);
        offset = offset + 32;

        let add = *vector::borrow(&payload, offset) == 1;
        offset = offset + 1;

        let (destination_chain_id, _) = read_u16(&payload, offset);

        (list_name, account, add, destination_chain_id)
    }

    // ================ Helper Functions ================

    fun read_u64(payload: &vector<u8>, offset: u64): (u64, u64) {
        let bytes = read_bytes(payload, offset, 8);
        (bytes_to_u64(bytes), offset + 8)
    }

    fun read_u16(payload: &vector<u8>, offset: u64): (u16, u64) {
        let bytes = read_bytes(payload, offset, 2);
        (bytes_to_u16(bytes), offset + 2)
    }

    fun read_bytes(payload: &vector<u8>, offset: u64, length: u64): vector<u8> {
        let mut result = vector::empty<u8>();
        let mut i = 0;
        while (i < length) {
            vector::push_back(&mut result, *vector::borrow(payload, offset + i));
            i = i + 1;
        };
        result
    }

    // Conversion functions
    fun bytes_to_u64(bytes: vector<u8>): u64 {
        assert!(vector::length(&bytes) == 8, E_INVALID_PAYLOAD_LENGTH);

        let mut result = 0u64;
        let mut i = 0;
        while (i < 8) {
            let byte_val = (*vector::borrow(&bytes, i) as u64);
            result = (result << 8) | byte_val;
            i = i + 1;
        };
        result
    }

    fun bytes_to_u16(bytes: vector<u8>): u16 {
        assert!(vector::length(&bytes) == 2, E_INVALID_PAYLOAD_LENGTH);

        let high = (*vector::borrow(&bytes, 0) as u16);
        let low = (*vector::borrow(&bytes, 1) as u16);
        (high << 8) | low
    }

    fun bytes_to_address(bytes: vector<u8>): address {
        assert!(vector::length(&bytes) == 32, E_INVALID_PAYLOAD_LENGTH);
        address::from_bytes(bytes)
    }

    // ============ M Token System Integration Functions ============

    // ============ Earner System Integration ============

    /// Add balance to earner tracking system
    fun add_to_earner_balance<CoinType>(
        state: &mut State<CoinType>,
        recipient: address,
        amount: u256,
        _ctx: &mut TxContext
    ) {
        // For now, we'll store this information in the registrar storage
        // In a full implementation, we would make direct calls to the earner package
        let balance_key = generate_earner_balance_key(recipient);

        // Get current balance or default to 0
        let current_balance = if (state::has_registrar_key(state, balance_key)) {
            let balance_bytes = *option::borrow(&state::get_registrar_value(state, balance_key));
            bytes_to_u256(balance_bytes)
        } else {
            0
        };

        // Update balance
        let new_balance = current_balance + amount;
        state::set_registrar_key(state, balance_key, u256_to_bytes(new_balance));
    }

    /// Generate key for earner balance storage
    fun generate_earner_balance_key(account: address): vector<u8> {
        let mut key = vector::empty<u8>();
        vector::append(&mut key, b"earner_balance:");
        let account_bytes = bcs::to_bytes(&account);
        vector::append(&mut key, account_bytes);
        key
    }

    /// Convert u256 to bytes
    fun u256_to_bytes(value: u256): vector<u8> {
        bcs::to_bytes(&value)
    }

    /// Convert bytes to u256
    fun bytes_to_u256(bytes: vector<u8>): u256 {
        // Simple conversion for now - in production would need proper deserialization
        if (vector::length(&bytes) == 0) {
            0
        } else if (vector::length(&bytes) >= 8) {
            // Read first 8 bytes as u64 and convert to u256
            let mut result = 0u256;
            let mut i = 0;
            while (i < 8) {
                let byte_val = (*vector::borrow(&bytes, i) as u256);
                result = (result << 8) | byte_val;
                i = i + 1;
            };
            result
        } else {
            // Simple conversion for shorter vectors
            let mut result = 0u256;
            let mut i = 0;
            while (i < vector::length(&bytes)) {
                let byte_val = (*vector::borrow(&bytes, i) as u256);
                result = (result << 8) | byte_val;
                i = i + 1;
            };
            result
        }
    }

    /// Update M Token index
    fun update_m_token_index<CoinType>(
        state: &mut State<CoinType>,
        index: u128,
        _ctx: &mut TxContext
    ) {
        state::set_current_index(state, index);
    }

    /// Set registrar key
    fun set_registrar_key<CoinType>(
        state: &mut State<CoinType>,
        key: vector<u8>,
        value: vector<u8>,
        _ctx: &mut TxContext
    ) {
        state::set_registrar_key(state, key, value);
    }

    /// Add to registrar list
    fun add_to_registrar_list<CoinType>(
        state: &mut State<CoinType>,
        _list_name: vector<u8>,
        _account: address,
        _ctx: &mut TxContext
    ) {
        if (!state::has_m_token_globals(state)) {
            return
        };

        // Placeholder: In a full implementation, this would add to a registrar list
        // For now, we acknowledge the operation but don't persist data
    }

    /// Remove from registrar list
    fun remove_from_registrar_list<CoinType>(
        state: &mut State<CoinType>,
        _list_name: vector<u8>,
        _account: address,
        _ctx: &mut TxContext
    ) {
        if (!state::has_m_token_globals(state)) {
            return
        };

        // Placeholder: In a full implementation, this would remove from a registrar list
        // For now, we acknowledge the operation but don't persist data
    }

    /// Mint M Tokens with index - with earner integration
    fun mint_m_token_with_index<CoinType>(
        state: &mut State<CoinType>,
        recipient: address,
        amount: u64,
        index: u128,
        ctx: &mut TxContext
    ) {
        // Update M Token index first
        update_m_token_index(state, index, ctx);

        // Mint coins
        let coins = coin::mint(state.borrow_treasury_cap_mut(), amount, ctx);

        // Add to earner balance tracking if earner system is enabled
        if (state::has_m_token_globals(state)) {
            add_to_earner_balance(state, recipient, (amount as u256), ctx);
        };

        // Transfer coins to recipient
        transfer::public_transfer(coins, recipient);
    }

}
