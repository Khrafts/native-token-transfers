module ntt::ntt {
    use wormhole::external_address::{Self, ExternalAddress};
    use wormhole::bytes32;
    use sui::balance::Balance;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin, CoinMetadata};
    use ntt_common::trimmed_amount::{Self, TrimmedAmount};
    use ntt::state::State;
    use ntt::outbox::{Self, OutboxKey};
    use ntt_common::native_token_transfer::{Self, NativeTokenTransfer};
    use ntt_common::ntt_manager_message::{Self, NttManagerMessage};
    use ntt_common::validated_transceiver_message::ValidatedTransceiverMessage;
    use ntt::upgrades::VersionGated;

    // Portal imports for M Token integration
    use portal::payload_encoder;

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
        if (state.has_m_token_globals()) {
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

    // ============ M Token Release Functions ============

    /// Internal M Token release logic - processes custom payloads and M Token transfers
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

    /// Process custom M payload types for M Token (M0IT/M0KT/M0LU)
    fun process_m_custom_payload<CoinType>(
        state: &mut State<CoinType>,
        payload: vector<u8>,
        ctx: &mut TxContext
    ): bool {
        if (vector::length(&payload) < 4) return false;

        let payload_type = payload_encoder::get_payload_type(&payload);

        if (payload_encoder::is_index_payload(&payload_type)) {
            // M0IT - Index Transfer
            let (index, _chain_id) = payload_encoder::decode_index_payload(payload);
            state.update_m_token_index(index, ctx);
            true
        } else if (payload_encoder::is_key_payload(&payload_type)) {
            // M0KT - Key Transfer
            let (key, value, _chain_id) = payload_encoder::decode_key_payload(payload);
            state.set_registrar_key(key, value);
            true
        } else if (payload_encoder::is_list_payload(&payload_type)) {
            // M0LU - List Update
            let (list_name, account, add, _chain_id) =
                payload_encoder::decode_list_update_payload(payload);

            if (add) {
                state.add_to_registrar_list(list_name, account);
            } else {
                state.remove_from_registrar_list(list_name, account);
            };
            true
        } else {
            false // Not a custom M payload
        }
    }

    /// Mint M Tokens with index update using NTT's treasury cap
    fun mint_m_token_with_index<CoinType>(
        state: &mut State<CoinType>,
        recipient: address,
        amount: u64,
        index: u128,
        ctx: &mut TxContext
    ) {
        let current_index = state.get_m_token_current_index();

        if (index > current_index) {
            // Mint with index update
            state.mint_m_token_with_index(recipient, (amount as u256), index, ctx);
        } else {
            // Mint without index update
            state.mint_m_token_no_index(recipient, (amount as u256), ctx);
        }
    }

}
