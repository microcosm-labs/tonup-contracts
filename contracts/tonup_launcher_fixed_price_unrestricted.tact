import "@stdlib/deploy";
import "@stdlib/ownable";
import "./transfer_helpers";

// ======================== Messages ========================
message Participate {
    amount: Int as coins;
}

message ParticipateConfirmation {
    amount: Int as coins;
}

message SetLauncherConfig {
    config: LauncherConfig;
}

message SetClaimStartTime {
    time: Int as uint32;
}

message AddDistributionPool {
    config: PoolConfig;
}

message DeleteDistributionPool {
    index: Int as uint32;
}

message ModifyDistributionPool {
    index: Int as uint32;
    config: PoolConfig;
}

message ManualTransferNotification {
    amount: Int as coins;
}

// ======================== Events ========================
message ParticipatedEvent {
    sender: Address;
    amount: Int as coins;
}

message ClaimedEvent {
    sender: Address;
    amount: Int as coins;
}

message RefundedEvent {
    sender: Address;
    amount: Int as coins;
}

message LauncherConfigSetEvent {
    config: LauncherConfig;
}

message ClaimStartTimeSetEvent {
    time: Int as uint32;
}

message DistritutionPoolAddedEvent {
    index: Int as uint32;
    config: PoolConfig;
}

message DistributionPoolModifiedEvent {
    index: Int as uint32;
    config: PoolConfig;
}

message ConfigValidatedEvent {
    timestamp: Int as uint32;
}

message FinalizedEvent {
    timestamp: Int as uint32;
    successful: Bool;
}

message FinalizationRefundEvent {
    amount: Int as coins;
    address: Address;
}

message DistributionEvent {
    amount: Int as coins;
    address: Address;
}
// ======================== Data Structures ========================
struct LauncherMetadata {
    launcher_name: String;
    launcher_type: String;
    launcher_version: String;
}

struct LauncherConfig {
    min_total_ton: Int as coins;
    max_total_ton: Int as coins;
    min_ton_per_tx: Int as coins;
    max_ton_per_user: Int as coins;
    tokens_per_ton: Int as coins;
    token_wallet_address: Address;  // Use `get_wallet_address(owner: Address)` of the jetton master to get the wallet address
    unsold_token_refund_address: Address;
    start_time: Int as uint32;
    end_time: Int as uint32;
}

struct PoolConfig {
    address: Address;
    share: Int as uint32;
}

struct ClaimData {
    address: Address;
    amount: Int as coins;
}

/// Launcher contract with a fixed price and no restrictions on who can participate
/// This contract is for fixed price launch with min and max contribution limits
/// If the min contribution limit is not met, the launch is considered unsuccessful and all funds are refunded
/// If the min contribution limit is met, the launch is considered successful and users can claim their tokens
/// When the max contribution limit is met, no more contributions are accepted
/// ## Admin setup steps:
/// 1. Set the configuration
/// 2. Set the claim start time
/// 3. Add distribution pools (at least one)
/// 4. Send enough tokens to the contract *with notification*
/// 5. Validate the config (launch would not start unless config is validated)
/// 6. Launch would start at the start time
/// 7. Finalize after the end time (users can only claim after finalization)
/// 8. Distribute ton after the end time
/// 9. Withdraw dust after distribution
contract TonupLauncherFixedPriceUnrestricted with Deployable, OwnableTransferable {
    const STORAGE_GAS_RESERVE: Int = ton("0.2");
    const GAS_CHECK_PARTICIPATE: Int = ton("0.1");
    const GAS_CHECK_CLAIM: Int = ton("0.15");
    const GAS_CHECK_REFUND: Int = ton("0.15");
    const GAS_CHECK_FINALIZE: Int = ton("0.3");
    const GAS_CHECK_DISTRIBUTE: Int = ton("1");

    const METADATA_NAME: String = "Test Launcher"; 
    const METADATA_TICKER: String = "TEST";  // OPT: use string at init
    const METADATA_TYPE: String = "First-come-first-served, Fixed-price, Unrestricted";
    const METADATA_VERSION: String = "2.0.0";

    owner: Address;
    config: LauncherConfig;

    total_ton_contributed: Int as coins = 0;
    total_ton_refunded: Int as coins = 0;
    config_validated: Bool = false;
    tokens_awaiting_launch: Int as coins = 0;
    claim_start_time: Int as uint32 = 4294967295;  // Initialize to long in the future
    participation: map<Address, Int as uint256>;
    distribution_number_pools: Int as uint32 = 0;
    distribution_pools: map<Int, PoolConfig>;
    distribution_complete: Bool = false;
    launch_finalized: Bool = false;
    launch_successful: Bool = false;


    init(owner: Address,
         config: LauncherConfig
    ) {
        self.owner = owner;
        self.config = config;

        emit(LauncherConfigSetEvent{config: config}.toCell());
    }

    // ======================== Contract Interface ========================

    receive(msg: TokenNotification) {
        if (msg.from == self.config.token_wallet_address) {
            self.tokens_awaiting_launch = self.tokens_awaiting_launch + msg.amount;
        }
    }

    receive(msg: TokenExcesses) {}

    // ======================== Admin Interface ========================
    // Fund the contract
    receive("fund gas") {}

    /// Set the configuration for the launcher
    /// Config parameters can be changed prior to launch
    receive(msg: SetLauncherConfig) {
        self.requireOwner();
        require(!self.config_validated || now() < self.config.start_time, "Already started");

        self.config = msg.config;
        emit(LauncherConfigSetEvent{config: msg.config}.toCell());
        refund_gas();
    }

    /// Set the time at which claims can be made
    receive(msg: SetClaimStartTime) {
        self.requireOwner();

        self.claim_start_time = msg.time;
        emit(ClaimStartTimeSetEvent{time: msg.time}.toCell());
        refund_gas();
    }

    /// Set distribution pools prior to start
    /// Up to 20 pools can be added
    receive(msg: AddDistributionPool) {
        self.requireOwner();
        require(now() < self.config.start_time, "Already started");
        require(self.distribution_number_pools < 20, "Too many pools");

        self.distribution_pools.set(self.distribution_number_pools, msg.config);
        self.distribution_number_pools = self.distribution_number_pools + 1;
        emit(DistritutionPoolAddedEvent{index: self.distribution_number_pools - 1, config: msg.config}.toCell());
        refund_gas();
    }

    /// Delete a distribution pool prior to start
    receive(msg: DeleteDistributionPool) {
        self.requireOwner();
        require(now() < self.config.start_time, "Already started");
        require(msg.index < self.distribution_number_pools, "Invalid index");

        self.distribution_pools.set(msg.index, PoolConfig{address: myAddress(), share: 0});
        emit(DistributionPoolModifiedEvent{index: msg.index, config: PoolConfig{address: myAddress(), share: 0}}.toCell());
        refund_gas();
    }

    /// Modify a distribution pool prior to start
    receive(msg: ModifyDistributionPool) {
        self.requireOwner();
        require(now() < self.config.start_time, "Already started");
        require(msg.index < self.distribution_number_pools, "Invalid index");

        self.distribution_pools.set(msg.index, msg.config);
        emit(DistributionPoolModifiedEvent{index: msg.index, config: msg.config}.toCell());
        refund_gas();
    }

    /// Manually notify the contract of a token transfer
    receive(msg: ManualTransferNotification) {
        self.requireOwner();
        require(now() < self.config.start_time, "Already started");

        self.tokens_awaiting_launch = self.tokens_awaiting_launch + msg.amount;
        refund_gas();
    }

    /// Validate config
    /// Must be called before launch
    receive("validate") {
        self.requireOwner();
        require(self.distribution_number_pools > 0, "Distribution pools not set");
        require(self.tokens_awaiting_launch >= self.config.max_total_ton * self.config.tokens_per_ton / ton("1") , "Not enough tokens"); // Very unlikely to overflow (need 1e59 tokens)

        self.config_validated = true;
        emit(ConfigValidatedEvent{timestamp: now()}.toCell());
        refund_gas();
    }

    /// Finalize after launch
    /// Any unsold tokens are refunded to the unsold_token_refund_address
    receive("finalize") {
        self.requireOwner();
        require(context().value >= self.GAS_CHECK_FINALIZE, "Not enough TON");
        require(now() > self.config.end_time, "Too early");

        let tokens_to_refund: Int = 0;
        if (self.total_ton_contributed < self.config.min_total_ton) {
            self.launch_successful = false;
            tokens_to_refund = self.tokens_awaiting_launch;
        } else {
            self.launch_successful = true;
            tokens_to_refund = self.tokens_awaiting_launch - self.total_ton_contributed * self.config.tokens_per_ton / ton("1");   // Very unlikely to overflow (need 1e59 tokens)
        }

        self.launch_finalized = true;
        emit(FinalizedEvent{timestamp: now(), successful: self.launch_successful}.toCell());
        if (tokens_to_refund > ton("0.1")) {
            send_jetton(self.config.token_wallet_address, self.config.unsold_token_refund_address, tokens_to_refund, 0, false, "finalize"); // QueryID 0
            emit(FinalizationRefundEvent{amount: tokens_to_refund, address: self.config.unsold_token_refund_address}.toCell());
        }
        refund_gas();
    }

    /// Distribute tons according to pool settings
    receive("distribute") {
        self.requireOwner();
        require(context().value >= self.GAS_CHECK_DISTRIBUTE, "Not enough TON");
        require(now() > self.config.end_time, "Too early");

        // Distribute ton only when successful
        if (self.launch_successful) {
            let amount_to_distribute: Int = min(myBalance() - context().value - self.STORAGE_GAS_RESERVE, self.total_ton_contributed);  // Safety precaution, should always equal to `total_ton_contributed`
        
            // Calculate shares
            let total_share: Int = 0;
            let i: Int = 0;
            while (i < self.distribution_number_pools) {
                total_share = total_share + (self.distribution_pools.get(i)!!).share;
                i = i + 1;
            }
            // Distribute
            i = 0;
            while (i < self.distribution_number_pools) {
                let pool_share: Int = (self.distribution_pools.get(i)!!).share;
                let pool_address: Address = (self.distribution_pools.get(i)!!).address;
                let pool_amount: Int = amount_to_distribute * pool_share / total_share;
                send_ton(pool_address, pool_amount, false, "Distribution".asComment());
                i = i + 1;
                emit(DistributionEvent{amount: pool_amount, address: pool_address}.toCell());
            }
        }
        self.distribution_complete = true;  // Mark as complete even if unsuccessful
        refund_gas();
    }

    /// Withdraw dust
    receive("withdraw dust") {
        self.requireOwner();
        require(self.distribution_complete, "Distribution not complete");

        let dust_to_claim: Int = 0;
        dust_to_claim = myBalance() - context().value - self.STORAGE_GAS_RESERVE + self.total_ton_refunded - self.total_ton_contributed;

        send_ton(self.owner, myBalance() - self.STORAGE_GAS_RESERVE, false, "Withdraw dust".asComment());
    }
    
    // ======================== User Interface ========================

    /// Users call this method to participate
    /// This can be called multiple times as long as the total amount does not exceed max_ton_per_user
    /// If the participation amount is 5 TON, the user needs to send 5.1 TON to cover gas fees
    receive(msg: Participate) {
        require(context().value == msg.amount + self.GAS_CHECK_PARTICIPATE, "Incorrect TON value");
        require(now() >= self.config.start_time, "Too early");
        require(now() < self.config.end_time, "Too late");
        require(self.config_validated, "Config not validated");
        require(self.total_ton_contributed + msg.amount <= self.config.max_total_ton, "Max TON limit exceeded");
        require(msg.amount >= self.config.min_ton_per_tx, "Min TON per tx not met");
        let current_participation: Int = 0;
        if (self.participation.get(sender()) != null) {
            current_participation = self.participation.get(sender())!!;
        }
        require(current_participation + msg.amount <= self.config.max_ton_per_user, "Max TON per user exceeded");
        

        self.total_ton_contributed = self.total_ton_contributed + msg.amount;
        self.participation.set(sender(), current_participation + msg.amount); 
        emit(ParticipatedEvent{sender: sender(), amount: msg.amount}.toCell());
    }

    /// Users call this method to claim their tokens
    /// The user must send 0.15 TON to cover gas fees
    receive("claim") {
        require(context().value >= self.GAS_CHECK_CLAIM, "Not enough TON");
        require(now() >= self.claim_start_time, "Too early");
        require(self.launch_finalized, "Launch not finalized");
        require(self.total_ton_contributed >= self.config.min_total_ton, "Min TON limit not met");
        require(self.participation.get(sender()) != null && self.participation.get(sender())!! != 0, "Nothing to claim");

        let claim_amount: Int = self.participation.get(sender())!! * self.config.tokens_per_ton / ton("1");
        
        self.participation.set(sender(), 0);

        send_jetton(self.config.token_wallet_address, sender(), claim_amount, 0, true, "claim");
        emit(ClaimedEvent{sender: sender(), amount: claim_amount}.toCell());
        refund_gas();
    }

    /// Users call this method to refund their tons
    /// The user must send 0.15 TON to cover gas fees
    receive("refund") {
        require(context().value >= self.GAS_CHECK_REFUND, "Not enough TON");
        require(now() >= self.claim_start_time, "Too early");
        require(self.launch_finalized, "Launch not finalized");
        require(self.total_ton_contributed < self.config.min_total_ton, "Min TON limit already met");
        require(self.participation.get(sender()) != null && self.participation.get(sender())!! != 0, "Nothing to claim");

        let claim_amount: Int = self.participation.get(sender())!!;
        
        self.participation.set(sender(), 0);
        self.total_ton_refunded = self.total_ton_refunded + claim_amount;

        send_ton(sender(), claim_amount, false, "Refund".asComment());
        emit(RefundedEvent{sender: sender(), amount: claim_amount}.toCell());
        refund_gas();
    }


    // TODO: bounced: from claim
    // We can skip this now because it would never bounce
    bounced(src: bounced<TokenTransfer>) {
        dump(src);
        //self.participation.set(src.destination, src.amount);
    }

    // ======================== Internal Methods ========================



    // ======================== View Interface ========================

    get fun config(): LauncherConfig {
        return self.config;
    }

    get fun totalTon(): Int {
        return self.total_ton_contributed;
    }

    get fun validated(): Bool {
        return self.config_validated;
    }

    get fun balance(): Int {
        return myBalance();
    }

    get fun participation(addr: Address): Int {
        if (self.participation.get(addr) == null) {
            return 0;
        }
        return self.participation.get(addr)!!;
    }

    get fun numberPools(): Int {
        return self.distribution_number_pools;
    }

    get fun poolConfig(index: Int): PoolConfig {
        return self.distribution_pools.get(index)!!;
    }

    get fun claimStartTime(): Int {
        return self.claim_start_time;
    }

    get fun launchFinalized(): Bool {
        return self.launch_finalized;
    }

    get fun launchSuccessful(): Bool {
        return self.launch_successful;
    }

    get fun tokensAwaitingLaunch(): Int {
        return self.tokens_awaiting_launch;
    }

    get fun metadataName(): String {
        return self.METADATA_NAME;
    }

    get fun metadataType(): String {
        return self.METADATA_TYPE;
    }

    get fun metadataVersion(): String {
        return self.METADATA_VERSION;
    }

    get fun metadataTicker(): String {
        return self.METADATA_TICKER;
    }

    get fun gasClaim(): Int {
        return self.GAS_CHECK_CLAIM;
    }

    get fun gasRefund(): Int {
        return self.GAS_CHECK_REFUND;
    }

    get fun gasParticipate(): Int {
        return self.GAS_CHECK_PARTICIPATE;
    }
}


// ======================== Notes ========================
// Audit: reentrancy
// Audit: gas limit attack