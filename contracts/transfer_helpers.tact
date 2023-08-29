message(0xf8a7ea5) TokenTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    response_destination: Address;
    custom_payload: Cell?;
    forward_ton_amount: Int as coins;
    forward_payload: Slice as remaining;
}

message(0x7362d09c) TokenNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    from: Address;
    forwardPayload: Slice as remaining;
}

message(0xd53276db) TokenExcesses {
    queryId: Int as uint64;
}

inline fun refund_gas() {
    send(SendParameters{
        to: sender(),
        value: 0,
        mode: SendRemainingValue + SendIgnoreErrors,
        bounce: false
    });
}

inline fun send_ton(
    to: Address, 
    value: Int, 
    bounce: Bool, 
    body: Cell?
) {
    if (value > 0) {
        send(SendParameters{
            value: value, 
            to: to, 
            bounce: bounce, 
            mode: SendIgnoreErrors, 
            body: body 
        });
    }
}

inline fun send_ton_with_ramaining(
    to: Address, 
    value: Int, 
    bounce: Bool, 
    body: Cell?
) {
    if (value > 0) {
        send(SendParameters{
            value: value, 
            to: to, 
            bounce: bounce, 
            mode: SendIgnoreErrors + SendRemainingValue, 
            body: body
        });
    }
}

inline fun send_jetton(
    jetton_address: Address, 
    to: Address, 
    amount: Int, 
    query_id: Int, 
    bounce: Bool,
    forward_payload: String
) {
    if (amount > 0) {
        send(SendParameters{
            value: ton("0.1"), 
            to: jetton_address, 
            mode: 0,
            body: TokenTransfer {
                queryId: query_id,
                amount: amount,
                destination: to,
                response_destination: myAddress(),
                custom_payload: null,
                forward_ton_amount: ton("0.01"),  // forward for notification
                forward_payload: forward_payload.asSlice()
            }.toCell(),
            bounce: bounce 
        });
    }
}

inline fun send_jetton_with_ton(
    jetton_address: Address, 
    to: Address, 
    amount: Int, 
    amount_ton: Int,
    query_id: Int, 
    bounce: Bool,
    forward_payload: String
) {
    if (amount > 0) {
        send(SendParameters{
            value: ton("0.1") + amount_ton, 
            to: jetton_address, 
            mode: 0,
            body: TokenTransfer {
                queryId: query_id,
                amount: amount,
                destination: to,
                response_destination: myAddress(),
                custom_payload: null,
                forward_ton_amount: amount_ton,
                forward_payload: forward_payload.asSlice()
            }.toCell(),
            bounce: bounce 
        });
    }
}