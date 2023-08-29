import "@stdlib/deploy";
import "@stdlib/ownable";
import "./transfer_helpers";

message ReadConsent {
    addr: Address;
}

message ConsentReply {
    addr: Address;
    accepted: Bool;
}

message ConsentEvent {
    addr: Address;
    timestamp: Int as uint32;
}

// On-chain ToS registry. Users must sign the message with a 0 TON transaction to use the services.
// Timestamp and signature can be read off chain.
// If there's any update to the ToS this contract needs to be redeployed.
contract TonupTosRegistry with Deployable, Ownable {
    const CURRENT_VERSION: Int = 1;
    const CONSENT_MSG: String = "I accept the ToS of TonUP. SHA256:8a5b2206e5cb5b3c1992e4f7e01c2a2f3daf34e1bf0d1b33fc4956be837b75ca";
    const STORAGE_GAS_RESERVE: Int = ton("0.2");
    const GAS_CHECK_ACCEPT: Int = ton("0.1");
    
    owner: Address;
    accepted: map<Address, Bool>;
    number_users: Int as uint32 = 0;
    
    init(owner: Address) {
        self.owner = owner;
    }

    // ======================== User Interface ========================

    /// Users send this message to accept ToS
    receive("I accept the ToS of TonUP. SHA256:8a5b2206e5cb5b3c1992e4f7e01c2a2f3daf34e1bf0d1b33fc4956be837b75ca") {
        require(!self.hasAccepted(sender()), "Already accepted");
        require(context().value >= self.GAS_CHECK_ACCEPT, "Not enough gas");
        self.accepted.set(sender(), true);
        self.number_users = self.number_users + 1;
        emit(ConsentEvent{addr: sender(), timestamp: now()}.toCell());
        // Refund remaining gas
        refund_gas();
    }

    // ======================== Admin Interface ========================
    // Fund the contract
    receive() {}

    /// Withdraw dust
    receive("withdraw dust") {
        self.requireOwner();
        send_ton_with_ramaining(
            self.owner,
            myBalance() - self.STORAGE_GAS_RESERVE, 
            false,
            "Withdraw dust".asComment()
        );
    }

    /// Read consent status on chain
    receive(msg: ReadConsent) {
        if (self.accepted.get(msg.addr) != null) {
            self.reply(ConsentReply{addr: msg.addr, accepted: self.accepted.get(msg.addr)!!}.toCell());
        } else {
            self.reply(ConsentReply{addr: msg.addr, accepted: false}.toCell());
        }
    }

    // ======================== Internal Methods ========================


    // ======================== View Interface ========================

    get fun hasAccepted(addr: Address): Bool {
        if (self.accepted.get(addr) != null) {
            return self.accepted.get(addr)!!;
        } else {
            return false;
        }
    }

    get fun consentMessage(): String {
        return self.CONSENT_MSG;
    }

    get fun currentVersion(): Int {
        return self.CURRENT_VERSION;
    }

    get fun numberUsers(): Int {
        return self.number_users;
    }

    get fun balance(): Int {
        return myBalance();
    }
}
