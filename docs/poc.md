# Proof Of Coverage

## POC Statem

1. Requesting
    1. Waiting 30 blocks to start POC
    2. Generate onion key pair
    3. Create POC request with:
        - Challenger's address
        - Hash of a secret (8 random bytes)
        - Hash of onion compact key
    4. Sign and submit transaction to blockchain
2. Mining
    1. Waiting for new block
    2. If block contains POC req transactions
    3. Target with entropy = secret + block hash
3. Targeting
    1. Find a suitable target out of current active gateways and entropy
    2. Challenge with entropy, target and geteway list
4. Challenging
    1. Attempt to build path from target and gateway list (if fails go back to targeting)
    2. Path is a list of `N` gateway address
    3. Create `N` secret hashes derived from entropy
    4. Construct onion packet
    5. Send onion packet to first gateway in the list (retry if fails) via P2P stream
5. Receiving
    1. P2P stream receives onion and sends it to `miner_onion_server`
    2. `miner_onion_server`receives packet from P2P stream or radio
        1. `miner_onion_server` decrypts packet
        2. `miner_onion_server` sends next layer to radio
        3. `miner_onion_server` sends receipt to challenger via P2P
            1. Check that there is a POC running for this onion compact key
            2. Create a POC receipt with
                - Challengee address
                - Time
                - Data
    3. Repeat
    4. Every time `miner_poc_statem` receives a receipt it:
        1. Validates it, verify that it comes from a challengee
        2. Accumulate receipts
    5. After timeout go to submitting
6. Submitting
    1. Create a POC receipts with:
        - All the receipts
        - Secret
        - Challenger's address
        - Fee
    2. Sign and submit transaction to blockchain
7. Waiting
    1. Wair for POC receipts to be mined or else retry


    
