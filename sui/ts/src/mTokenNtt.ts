import { SuiNtt } from "./ntt.js";
import { Transaction } from "@mysten/sui/transactions";
import type { AccountAddress, UnsignedTransaction, ChainAddress } from "@wormhole-foundation/sdk-definitions";
import type { Network, ChainId } from "@wormhole-foundation/sdk-base";
import type { SuiChains } from "@wormhole-foundation/sdk-sui";

// M Token specific payload types
export enum MTokenPayloadType {
  IndexTransfer = 1, // M0IT - Index Transfer
  KeyTransfer = 2,   // M0KT - Key Transfer
  ListUpdate = 3     // M0LU - List Update
}

export interface MTokenIndexTransferPayload {
  type: MTokenPayloadType.IndexTransfer;
  index: bigint;
}

export interface MTokenKeyTransferPayload {
  type: MTokenPayloadType.KeyTransfer;
  key: Uint8Array;
  value: Uint8Array;
}

export interface MTokenListUpdatePayload {
  type: MTokenPayloadType.ListUpdate;
  list: Uint8Array;
  account: string;
  add: boolean; // true = add, false = remove
}

export type MTokenPayload =
  | MTokenIndexTransferPayload
  | MTokenKeyTransferPayload
  | MTokenListUpdatePayload;

// M Token specific state interfaces
export interface MTokenEarnerState {
  isEarning: boolean;
  balance: bigint;
  lastClaimIndex: bigint;
}

export interface MTokenGlobalState {
  currentIndex: bigint;
  totalEarningSupply: bigint;
  totalNonEarningSupply: bigint;
  registrarAddress: string;
}

/**
 * Extended NTT class with M Token specific functionality
 */
export class MTokenNtt<N extends Network, C extends SuiChains> extends SuiNtt<N, C> {

  /**
   * Get M Token earner global state
   */
  async getEarnerGlobalState(): Promise<MTokenGlobalState | null> {
    try {
      const state = await this.provider.getObject({
        id: this.contracts.ntt!["manager"],
        options: { showContent: true }
      });

      if (!state.data?.content || state.data.content.dataType !== 'moveObject') {
        return null;
      }

      const fields = (state.data.content as any).fields;
      const earnerGlobal = fields.earner_global;

      if (!earnerGlobal) return null;

      return {
        currentIndex: BigInt(earnerGlobal.fields.indexing.fields.current_index || '0'),
        totalEarningSupply: BigInt(earnerGlobal.fields.total_earning_supply || '0'),
        totalNonEarningSupply: BigInt(earnerGlobal.fields.total_non_earning_supply || '0'),
        registrarAddress: earnerGlobal.fields.registrar || ''
      };
    } catch (error) {
      console.warn('Failed to get earner global state:', error);
      return null;
    }
  }

  /**
   * Get M Token account earning state
   */
  async getAccountEarningState(account: AccountAddress<C>): Promise<MTokenEarnerState | null> {
    try {
      const state = await this.provider.getObject({
        id: this.contracts.ntt!["manager"],
        options: { showContent: true }
      });

      if (!state.data?.content || state.data.content.dataType !== 'moveObject') {
        return null;
      }

      const fields = (state.data.content as any).fields;
      const earnerGlobal = fields.earner_global?.fields;

      if (!earnerGlobal) return null;

      const balances = earnerGlobal.balances?.fields;
      const accountAddress = account.toString();
      const accountBalance = balances?.[accountAddress];

      if (!accountBalance) {
        return {
          isEarning: false,
          balance: 0n,
          lastClaimIndex: 0n
        };
      }

      return {
        isEarning: accountBalance.fields.is_earning || false,
        balance: BigInt(accountBalance.fields.raw_balance || '0'),
        lastClaimIndex: BigInt(accountBalance.fields.last_claim_index || '0')
      };
    } catch (error) {
      console.warn('Failed to get account earning state:', error);
      return null;
    }
  }

  /**
   * Get current M Token index from NTT state
   */
  async getCurrentIndex(): Promise<bigint> {
    try {
      const stateAddress = this.contracts.ntt!["manager"];
      const packageId = await this.getPackageId();

      // Call the view function to get current index
      const result = await this.provider.devInspectTransactionBlock({
        transactionBlock: (() => {
          const tx = new Transaction();
          tx.moveCall({
            target: `${packageId}::state::get_m_token_current_index`,
            typeArguments: [this.contracts.ntt!["token"]],
            arguments: [tx.object(stateAddress)]
          });
          return tx;
        })(),
        sender: "0x0000000000000000000000000000000000000000000000000000000000000000"
      });

      if (result.results?.[0]?.returnValues?.[0]) {
        const bytes = result.results[0].returnValues[0][0];
        return BigInt('0x' + Buffer.from(bytes).toString('hex'));
      }

      return 0n;
    } catch (error) {
      console.warn('Failed to get current index:', error);
      return 0n;
    }
  }

  /**
   * Check if this NTT state has M Token globals configured
   */
  async hasMTokenGlobals(): Promise<boolean> {
    try {
      const stateAddress = this.contracts.ntt!["manager"];
      const packageId = await this.getPackageId();

      const result = await this.provider.devInspectTransactionBlock({
        transactionBlock: (() => {
          const tx = new Transaction();
          tx.moveCall({
            target: `${packageId}::state::has_m_token_globals`,
            typeArguments: [this.contracts.ntt!["token"]],
            arguments: [tx.object(stateAddress)]
          });
          return tx;
        })(),
        sender: "0x0000000000000000000000000000000000000000000000000000000000000000"
      });

      if (result.results?.[0]?.returnValues?.[0]) {
        const bytes = result.results[0].returnValues[0][0];
        return bytes[0] === 1;
      }

      return false;
    } catch (error) {
      console.warn('Failed to check M Token globals:', error);
      return false;
    }
  }

  /**
   * Transfer tokens with M Token payload (for index updates, key transfers, etc.)
   */
  async *transferWithMTokenPayload(
    amount: bigint,
    destination: ChainId,
    recipient: ChainAddress,
    payload: MTokenPayload,
    payer?: AccountAddress<C>
  ): AsyncGenerator<UnsignedTransaction<N, C>> {
    // Serialize the M Token payload with destination chain ID
    const serializedPayload = this.serializeMTokenPayload(payload, destination);

    // Use the existing transfer method with payload
    yield* this.transfer(
      payer || { address: { toString: () => "0x0000000000000000000000000000000000000000000000000000000000000000" } } as AccountAddress<C>,
      amount,
      recipient,
      { payload: serializedPayload } as any
    );
  }

  /**
   * Mint M Token with index update (used by NTT when receiving from Hub)
   * This is typically called internally by the NTT system
   */
  async *mintWithIndex(
    recipient: AccountAddress<C>,
    amount: bigint,
    index: bigint,
    payer?: AccountAddress<C>
  ): AsyncGenerator<UnsignedTransaction<N, C>> {
    const txb = new Transaction();
    const stateAddress = this.contracts.ntt!["manager"];

    // This calls the internal mint function with index update
    const packageId = await this.getPackageId();
    txb.moveCall({
      target: `${packageId}::state::mint_m_token_with_index`,
      typeArguments: [this.contracts.ntt!["token"]],
      arguments: [
        txb.object(stateAddress),
        txb.pure.address(recipient.address.toString()),
        txb.pure.u64(amount.toString()),
        txb.pure.u128(index.toString())
      ]
    });

    yield this.buildTransaction(txb, payer);
  }

  /**
   * Mint M Token without index update (for regular minting)
   */
  async *mintNoIndex(
    recipient: AccountAddress<C>,
    amount: bigint,
    payer?: AccountAddress<C>
  ): AsyncGenerator<UnsignedTransaction<N, C>> {
    const txb = new Transaction();
    const stateAddress = this.contracts.ntt!["manager"];

    // This calls the internal mint function without index update
    const packageId = await this.getPackageId();
    txb.moveCall({
      target: `${packageId}::state::mint_m_token_no_index`,
      typeArguments: [this.contracts.ntt!["token"]],
      arguments: [
        txb.object(stateAddress),
        txb.pure.address(recipient.address.toString()),
        txb.pure.u64(amount.toString())
      ]
    });

    yield this.buildTransaction(txb, payer);
  }

  /**
   * Check if account is approved earner
   */
  async isApprovedEarner(account: AccountAddress<C>): Promise<boolean> {
    try {
      const state = await this.provider.getObject({
        id: this.contracts.ntt!["manager"],
        options: { showContent: true }
      });

      if (!state.data?.content || state.data.content.dataType !== 'moveObject') {
        return false;
      }

      const fields = (state.data.content as any).fields;
      const earnerGlobal = fields.earner_global?.fields;

      if (!earnerGlobal) return false;

      const approvedEarners = earnerGlobal.approved_earners?.fields;
      const accountAddress = account.toString();

      return approvedEarners?.[accountAddress]?.fields || false;
    } catch (error) {
      console.warn('Failed to check approved earner status:', error);
      return false;
    }
  }

  /**
   * Get registrar value by key
   */
  async getRegistrarValue(key: Uint8Array): Promise<Uint8Array | null> {
    try {
      const state = await this.provider.getObject({
        id: this.contracts.ntt!["manager"],
        options: { showContent: true }
      });

      if (!state.data?.content || state.data.content.dataType !== 'moveObject') {
        return null;
      }

      const fields = (state.data.content as any).fields;
      const registrarGlobal = fields.registrar_global?.fields;

      if (!registrarGlobal) return null;

      const values = registrarGlobal.values?.fields;
      const keyStr = Buffer.from(key).toString('hex');
      const value = values?.[keyStr];

      return value ? Buffer.from(value, 'hex') : null;
    } catch (error) {
      console.warn('Failed to get registrar value:', error);
      return null;
    }
  }


  /**
   * Serialize M Token payload for cross-chain message
   * Uses the same encoding format as the Move payload_encoder module
   */
  private serializeMTokenPayload(payload: MTokenPayload, destinationChainId?: number): Uint8Array {
    switch (payload.type) {
      case MTokenPayloadType.IndexTransfer:
        // Format: "M0IT" prefix + index (u64) + destination_chain_id (u16)
        return this.encodeIndexPayload(payload.index, destinationChainId || 0);

      case MTokenPayloadType.KeyTransfer:
        // Format: "M0KT" prefix + key (32 bytes) + value (32 bytes) + destination_chain_id (u16)
        return this.encodeKeyPayload(payload.key, payload.value, destinationChainId || 0);

      case MTokenPayloadType.ListUpdate:
        // Format: "M0LU" prefix + list_name (32 bytes) + account (32 bytes) + add (u8) + destination_chain_id (u16)
        return this.encodeListUpdatePayload(payload.list, payload.account, payload.add, destinationChainId || 0);
    }
  }

  /**
   * Deserialize M Token payload from cross-chain message
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  private deserializeMTokenPayload(data: Uint8Array): MTokenPayload {
    // Extract prefix to determine payload type
    if (data.length < 4) {
      throw new Error('Payload too short to determine type');
    }

    const prefix = Buffer.from(data.subarray(0, 4)).toString();

    if (prefix === 'M0IT') {
      return this.decodeIndexPayload(data.subarray(4));
    } else if (prefix === 'M0KT') {
      return this.decodeKeyPayload(data.subarray(4));
    } else if (prefix === 'M0LU') {
      return this.decodeListUpdatePayload(data.subarray(4));
    } else {
      throw new Error(`Unknown M Token payload prefix: ${prefix}`);
    }
  }

  // ================ Index Payload Encoding ================

  /**
   * Encode M Token index payload (M0IT)
   */
  private encodeIndexPayload(index: bigint, destinationChainId: number): Uint8Array {
    const prefix = new Uint8Array(Buffer.from('M0IT', 'utf8'));
    const indexBytes = new Uint8Array(this.encodeU64(index));
    const chainIdBytes = new Uint8Array(this.encodeU16(BigInt(destinationChainId)));

    return this.concatUint8Arrays([prefix, indexBytes, chainIdBytes]);
  }

  /**
   * Decode M Token index payload
   */
  private decodeIndexPayload(data: Uint8Array): MTokenIndexTransferPayload {
    if (data.length < 10) { // 8 bytes index + 2 bytes chain_id
      throw new Error('Index payload too short');
    }

    const index = this.decodeU64(Buffer.from(data.subarray(0, 8)));
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const _chainId = this.decodeU16(Buffer.from(data.subarray(8, 10)));

    return {
      type: MTokenPayloadType.IndexTransfer,
      index
    };
  }

  // ================ Key Payload Encoding ================

  /**
   * Encode Registrar key payload (M0KT)
   */
  private encodeKeyPayload(key: Uint8Array, value: Uint8Array, destinationChainId: number): Uint8Array {
    const prefix = new Uint8Array(Buffer.from('M0KT', 'utf8'));
    const keyPadded = new Uint8Array(this.padTo32Bytes(key));
    const valuePadded = new Uint8Array(this.padTo32Bytes(value));
    const chainIdBytes = new Uint8Array(this.encodeU16(BigInt(destinationChainId)));

    return this.concatUint8Arrays([prefix, keyPadded, valuePadded, chainIdBytes]);
  }

  /**
   * Decode Registrar key payload
   */
  private decodeKeyPayload(data: Uint8Array): MTokenKeyTransferPayload {
    if (data.length < 66) { // 32 bytes key + 32 bytes value + 2 bytes chain_id
      throw new Error('Key payload too short');
    }

    const key = data.subarray(0, 32);
    const value = data.subarray(32, 64);
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const _chainId = this.decodeU16(Buffer.from(data.subarray(64, 66)));

    return {
      type: MTokenPayloadType.KeyTransfer,
      key: key,
      value: value
    };
  }

  // ================ List Update Payload Encoding ================

  /**
   * Encode Registrar list update payload (M0LU)
   */
  private encodeListUpdatePayload(list: Uint8Array, account: string, add: boolean, destinationChainId: number): Uint8Array {
    const prefix = new Uint8Array(Buffer.from('M0LU', 'utf8'));
    const listPadded = new Uint8Array(this.padTo32Bytes(list));
    const accountBytes = new Uint8Array(this.addressToBytes(account));
    const flag = new Uint8Array([add ? 1 : 0]);
    const chainIdBytes = new Uint8Array(this.encodeU16(BigInt(destinationChainId)));

    return this.concatUint8Arrays([prefix, listPadded, accountBytes, flag, chainIdBytes]);
  }

  /**
   * Decode Registrar list update payload
   */
  private decodeListUpdatePayload(data: Uint8Array): MTokenListUpdatePayload {
    if (data.length < 67) { // 32 bytes list + 32 bytes account + 1 byte flag + 2 bytes chain_id
      throw new Error('List update payload too short');
    }

    const list = data.subarray(0, 32);
    const accountBytes = data.subarray(32, 64);
    const add = data[64] === 1;
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const _chainId = this.decodeU16(Buffer.from(data.subarray(65, 67)));

    return {
      type: MTokenPayloadType.ListUpdate,
      list: list,
      account: this.bytesToAddress(accountBytes),
      add: add
    };
  }

  // ================ Helper Functions ================

  /**
   * Encode u64 as big-endian bytes (matching Move module format)
   */
  private encodeU64(value: bigint): Buffer {
    const buffer = Buffer.alloc(8);
    buffer.writeBigUInt64BE(value, 0);
    return buffer;
  }

  /**
   * Decode u64 from big-endian bytes
   */
  private decodeU64(data: Buffer): bigint {
    if (data.length !== 8) {
      throw new Error('Invalid u64 length');
    }
    return data.readBigUInt64BE(0);
  }

  /**
   * Encode u16 as big-endian bytes
   */
  private encodeU16(value: bigint): Buffer {
    const buffer = Buffer.alloc(2);
    buffer.writeUInt16BE(Number(value), 0);
    return buffer;
  }

  /**
   * Decode u16 from big-endian bytes
   */
  private decodeU16(data: Buffer): number {
    if (data.length !== 2) {
      throw new Error('Invalid u16 length');
    }
    return data.readUInt16BE(0);
  }

  /**
   * Pad data to exactly 32 bytes (truncate if longer, pad with zeros if shorter)
   */
  private padTo32Bytes(data: Uint8Array): Uint8Array {
    const result = new Uint8Array(32);
    const copyLength = Math.min(data.length, 32);
    result.set(data.subarray(0, copyLength));
    // Remaining bytes are already zero-padded by Uint8Array constructor
    return result;
  }

  /**
   * Convert address string to 32-byte representation
   */
  private addressToBytes(address: string): Uint8Array {
    // Remove 0x prefix and convert to buffer
    const cleanAddress = address.replace('0x', '');
    const addressBuffer = Buffer.from(cleanAddress, 'hex');

    // Pad to 32 bytes with leading zeros (matching Move module)
    const result = new Uint8Array(32);
    result.set(addressBuffer, 32 - addressBuffer.length);
    return result;
  }

  /**
   * Convert 32-byte buffer to address string
   */
  private bytesToAddress(data: Uint8Array): string {
    if (data.length !== 32) {
      throw new Error('Invalid address bytes length');
    }

    // Remove leading zeros and convert to hex string
    const hex = Buffer.from(data).toString('hex').replace(/^0+/, '');
    return '0x' + (hex || '0');
  }

  /**
   * Concatenate Uint8Arrays
   */
  private concatUint8Arrays(arrays: Uint8Array[]): Uint8Array {
    const totalLength = arrays.reduce((sum, arr) => sum + arr.length, 0);
    const result = new Uint8Array(totalLength);
    let offset = 0;

    for (const arr of arrays) {
      result.set(arr, offset);
      offset += arr.length;
    }

    return result;
  }

  /**
   * Build transaction wrapper
   */
  private buildTransaction(
    txb: Transaction,
    payer?: AccountAddress<C>
  ): UnsignedTransaction<N, C> {
    return {
      transaction: txb,
      network: this.network,
      chain: this.chain,
      description: "",
      parallelizable: false
    } as UnsignedTransaction<N, C>;
  }
}

// Re-export for convenience
export { SuiNtt };