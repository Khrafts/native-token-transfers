module portal::earner {
    use sui::table::{Self, Table};
    use sui::event;
    use portal::continuous_indexing::{Self, ContinuousIndexing};
    use portal::continuous_indexing_math::{divide_up, multiply_down};

    // ============ Error Codes ============

    /// Error when there is insufficient balance
    const EInsufficientBalance: u64 = 2;

    /// Error when calling stopEarning for an approved earner
    const EIsApprovedEarner: u64 = 3;

    /// Error when calling startEarning for a non-approved earner
    const ENotApprovedEarner: u64 = 4;

    /// Error when account balance not found
    const EAccountNotFound: u64 = 11;

    // ============ Structs ============

    /// Account balance information
    /// Tracks both earning and non-earning balances
    public struct AccountBalance has store {
        /// True if the account is earning, false otherwise
        is_earning: bool,
        /// Balance (for non-earning) or balance principal (for earning)
        /// uint240 in Solidity → u256 in Sui for safety
        raw_balance: u256,
        /// Last claim index (only relevant for earning accounts)
        /// Tracks the index when yield was last claimed
        last_claim_index: u128
    }

    /// Global Earner state - handles all yield and index logic
    public struct EarnerGlobal has key, store {
        id: UID,
        /// Continuous indexing state
        indexing: ContinuousIndexing,
        /// Registrar address for earner approvals
        registrar: address,
        /// Total non-earning supply (uint240 → u256)
        total_non_earning_supply: u256,
        /// Principal of total earning supply (uint112 → u128)
        principal_of_total_earning_supply: u128,
        /// Actual total earning supply (tracked directly for exact consistency)
        total_earning_supply: u256,
        /// Account balances table
        balances: Table<address, AccountBalance>,
        /// Approved earners table (managed by registrar logic)
        approved_earners: Table<address, bool>
    }

    /// Earner capability - gates all earner operations
    /// NTT State owns one, separate account holds another for claims
    public struct EarnerCap has key, store {
        id: UID
    }

    // ============ Events ============

    public struct StartEarning has copy, drop {
        account: address
    }

    public struct StopEarning has copy, drop {
        account: address
    }

    public struct IndexUpdate has copy, drop {
        old_index: u128,
        new_index: u128
    }

    // ============ Init ============

    fun init(ctx: &mut TxContext) {
        // Create and transfer capabilities to the deployer
        // These will be used to set up NTT integration
        let earner_cap_for_ntt = EarnerCap {
            id: object::new(ctx)
        };

        let earner_cap_for_claims = EarnerCap {
            id: object::new(ctx)
        };

        // Transfer both caps to deployer
        transfer::public_transfer(earner_cap_for_ntt, tx_context::sender(ctx));
        transfer::public_transfer(earner_cap_for_claims, tx_context::sender(ctx));
    }

    // ============ Public Functions ============

    /// Create earner global state (called during setup)
    public fun create_earner_global(
        registrar: address,
        ctx: &mut TxContext
    ): EarnerGlobal {
        EarnerGlobal {
            id: object::new(ctx),
            indexing: continuous_indexing::new(ctx),
            registrar,
            total_non_earning_supply: 0,
            principal_of_total_earning_supply: 0,
            total_earning_supply: 0,
            balances: table::new(ctx),
            approved_earners: table::new(ctx)
        }
    }


    /// Update the current index (called from NTT when processing M0IT payloads)
    public fun update_index(
        global: &mut EarnerGlobal,
        _cap: &EarnerCap,
        new_index: u128,
        _ctx: &mut TxContext
    ) {
        let old_index = continuous_indexing::current_index(&global.indexing);
        continuous_indexing::update_index(&mut global.indexing, new_index, 0); // TODO: use proper timestamp

        event::emit(IndexUpdate {
            old_index,
            new_index
        });
    }

    /// Get current index
    public fun current_index(global: &EarnerGlobal): u128 {
        continuous_indexing::current_index(&global.indexing)
    }

    /// Check if index is initialized
    public fun is_index_initialized(global: &EarnerGlobal): bool {
        continuous_indexing::current_index(&global.indexing) != 0
    }

    /// Add account balance when tokens are minted
    public fun add_account_balance(
        global: &mut EarnerGlobal,
        _cap: &EarnerCap,
        account: address,
        amount: u256,
        _ctx: &mut TxContext
    ) {
        if (!table::contains(&global.balances, account)) {
            table::add(&mut global.balances, account, AccountBalance {
                is_earning: false,
                raw_balance: amount,
                last_claim_index: 0
            });
        } else {
            let account_balance = table::borrow_mut(&mut global.balances, account);
            account_balance.raw_balance = account_balance.raw_balance + amount;
        };

        // Add to non-earning supply by default
        global.total_non_earning_supply = global.total_non_earning_supply + amount;
    }

    /// Remove account balance when tokens are burned
    public fun remove_account_balance(
        global: &mut EarnerGlobal,
        _cap: &EarnerCap,
        account: address,
        amount: u256,
        _ctx: &mut TxContext
    ) {
        assert!(table::contains(&global.balances, account), EAccountNotFound);

        let account_balance = table::borrow_mut(&mut global.balances, account);

        if (account_balance.is_earning) {
            // Extract values before calculations to avoid borrowing conflicts
            let principal = account_balance.raw_balance;
            let last_claim_index = account_balance.last_claim_index;
            let current_index = continuous_indexing::current_index(&global.indexing);

            // Convert earning balance to get actual balance
            let actual_balance = balance_of_earning_values(principal, last_claim_index, current_index);
            assert!(actual_balance >= amount, EInsufficientBalance);

            // Calculate new principal after removing amount
            let new_balance = actual_balance - amount;
            let new_principal = present_value_of(new_balance, current_index);

            // Update earning supply tracking
            global.principal_of_total_earning_supply = global.principal_of_total_earning_supply - (account_balance.raw_balance as u128) + (new_principal as u128);
            global.total_earning_supply = global.total_earning_supply - amount;

            account_balance.raw_balance = new_principal;
            account_balance.last_claim_index = current_index;
        } else {
            // Simple non-earning balance
            assert!(account_balance.raw_balance >= amount, EInsufficientBalance);
            account_balance.raw_balance = account_balance.raw_balance - amount;
            global.total_non_earning_supply = global.total_non_earning_supply - amount;
        };

        // Note: We keep the account balance entry even if balance becomes 0
        // This preserves earning status and other account state
    }

    /// Start earning for an account
    public fun start_earning(
        global: &mut EarnerGlobal,
        _cap: &EarnerCap,
        account: address,
        _ctx: &mut TxContext
    ) {
        assert!(is_approved_earner(global, account), ENotApprovedEarner);
        assert!(table::contains(&global.balances, account), EAccountNotFound);

        let account_balance = table::borrow_mut(&mut global.balances, account);

        if (!account_balance.is_earning) {
            let balance = account_balance.raw_balance;
            let current_index = continuous_indexing::current_index(&global.indexing);

            // Convert to principal
            let principal = present_value_of(balance, current_index);

            // Update tracking
            global.total_non_earning_supply = global.total_non_earning_supply - balance;
            global.principal_of_total_earning_supply = global.principal_of_total_earning_supply + (principal as u128);
            global.total_earning_supply = global.total_earning_supply + balance;

            // Update account
            account_balance.is_earning = true;
            account_balance.raw_balance = principal;
            account_balance.last_claim_index = current_index;

            event::emit(StartEarning { account });
        }
    }

    /// Stop earning for an account
    public fun stop_earning(
        global: &mut EarnerGlobal,
        _cap: &EarnerCap,
        account: address,
        _ctx: &mut TxContext
    ) {
        assert!(!is_approved_earner(global, account), EIsApprovedEarner);
        assert!(table::contains(&global.balances, account), EAccountNotFound);

        let account_balance = table::borrow_mut(&mut global.balances, account);

        if (account_balance.is_earning) {
            // Extract values before calculations to avoid borrowing conflicts
            let principal = account_balance.raw_balance;
            let last_claim_index = account_balance.last_claim_index;
            let current_index = continuous_indexing::current_index(&global.indexing);

            // Convert back to actual balance
            let actual_balance = balance_of_earning_values(principal, last_claim_index, current_index);

            // Update tracking
            global.principal_of_total_earning_supply = global.principal_of_total_earning_supply - (account_balance.raw_balance as u128);
            global.total_earning_supply = global.total_earning_supply - actual_balance;
            global.total_non_earning_supply = global.total_non_earning_supply + actual_balance;

            // Update account
            account_balance.is_earning = false;
            account_balance.raw_balance = actual_balance;
            account_balance.last_claim_index = 0;

            event::emit(StopEarning { account });
        }
    }

    /// Get balance of an account
    public fun balance_of(global: &EarnerGlobal, account: address): u256 {
        if (!table::contains(&global.balances, account)) {
            return 0
        };

        let account_balance = table::borrow(&global.balances, account);

        if (account_balance.is_earning) {
            balance_of_earning(global, account_balance.raw_balance, account_balance.last_claim_index)
        } else {
            account_balance.raw_balance
        }
    }

    /// Check if account is earning
    public fun is_earning(global: &EarnerGlobal, account: address): bool {
        if (!table::contains(&global.balances, account)) {
            return false
        };

        table::borrow(&global.balances, account).is_earning
    }

    /// Check if account is approved earner
    public fun is_approved_earner(global: &EarnerGlobal, account: address): bool {
        table::contains(&global.approved_earners, account) &&
        *table::borrow(&global.approved_earners, account)
    }

    /// Add approved earner (called from registrar via NTT)
    public fun add_approved_earner(
        global: &mut EarnerGlobal,
        _cap: &EarnerCap,
        account: address
    ) {
        if (table::contains(&global.approved_earners, account)) {
            *table::borrow_mut(&mut global.approved_earners, account) = true;
        } else {
            table::add(&mut global.approved_earners, account, true);
        }
    }

    /// Remove approved earner (called from registrar via NTT)
    public fun remove_approved_earner(
        global: &mut EarnerGlobal,
        _cap: &EarnerCap,
        account: address
    ) {
        if (table::contains(&global.approved_earners, account)) {
            *table::borrow_mut(&mut global.approved_earners, account) = false;
        }
    }

    /// Get total supply
    public fun total_supply(global: &EarnerGlobal): u256 {
        global.total_non_earning_supply + global.total_earning_supply
    }

    /// Get total earning supply
    public fun total_earning_supply(global: &EarnerGlobal): u256 {
        global.total_earning_supply
    }

    /// Get total non-earning supply
    public fun total_non_earning_supply(global: &EarnerGlobal): u256 {
        global.total_non_earning_supply
    }

    // ============ Internal Helper Functions ============

    /// Calculate balance for earning account
    fun balance_of_earning(
        global: &EarnerGlobal,
        principal: u256,
        last_claim_index: u128
    ): u256 {
        let current_index = continuous_indexing::current_index(&global.indexing);
        balance_of_earning_values(principal, last_claim_index, current_index)
    }

    /// Helper function to calculate balance without borrowing global
    fun balance_of_earning_values(
        principal: u256,
        last_claim_index: u128,
        current_index: u128
    ): u256 {
        if (current_index == 0 || last_claim_index == 0) {
            return principal
        };

        future_value_of(principal, current_index, last_claim_index)
    }

    /// Calculate present value (convert balance to principal)
    fun present_value_of(balance: u256, index: u128): u256 {
        if (index == 0) {
            return balance
        };

        (divide_up(balance, index) as u256)
    }

    /// Calculate future value (convert principal to balance)
    fun future_value_of(principal: u256, current_index: u128, last_claim_index: u128): u256 {
        if (current_index == 0 || last_claim_index == 0) {
            return principal
        };

        if (current_index == last_claim_index) {
            return principal
        };

        multiply_down((principal as u128), current_index / last_claim_index)
    }
}