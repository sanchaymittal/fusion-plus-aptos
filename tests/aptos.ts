import {Account, Aptos, AptosConfig, Network, NetworkToNetworkName, Ed25519PrivateKey} from '@aptos-labs/ts-sdk'
import * as dotenv from 'dotenv'
import {ethers} from 'ethers'

dotenv.config()

const privateKey = new Ed25519PrivateKey(process.env.PRIVATE_KEY as string)
const account = Account.fromPrivateKey({privateKey})

// Default to devnet, but allow for overriding
const APTOS_NETWORK: Network = NetworkToNetworkName[process.env.APTOS_NETWORK ?? Network.DEVNET]
// const APTOS_NETWORK: Network = NetworkToNetworkName[NODE];
const config = new AptosConfig({network: APTOS_NETWORK})
const client = new Aptos(config)
const profile_addr = '0xbf4897e1461fb38861f8431f68b1332d90dd62e3f0d454470b6fc9278dd8bccc'
const SRC_COIN_TYPE = `${profile_addr}::my_token::SimpleToken`
const secret = ethers.toUtf8Bytes('my_secret_password_for_swap_test')

async function initialize_token(): Promise<void> {
    const payload = {
        function: `${profile_addr}::my_token::initialize`,
        typeArguments: [],
        functionArguments: [
            'Simple Token', // name: String
            'SIMPLE', // symbol: String
            8, // decimals: u8
            true // monitor_supply: bool
        ]
    }

    await signAndSubmit(payload)
}

async function register_token(): Promise<void> {
    const payload = {
        function: `${profile_addr}::my_token::register`,
        typeArguments: [],
        functionArguments: []
    }

    await signAndSubmit(payload)
}

async function mint_token(): Promise<void> {
    const payload = {
        function: `${profile_addr}::my_token::mint`,
        typeArguments: [],
        functionArguments: [
            account.accountAddress.toString(), // to: address
            '1000000000' // amount: u64 (adjust as needed)
        ]
    }

    await signAndSubmit(payload)
}

async function initialize_ledger(): Promise<void> {
    const payload = {
        function: `${profile_addr}::fusion_plus::initialize_ledger`,
        typeArguments: [SRC_COIN_TYPE],
        functionArguments: []
    }
    await signAndSubmit(payload)
}

async function anounce_order(): Promise<void> {
    // -------------- user-supplied values --------------------------------
    const srcAmount = 10_000 // 1 APT if decimals = 6
    const minDstAmount = 10_000
    const expiresInSecs = 3_600 // 1 hour

    const stringBytes = ethers.toUtf8Bytes('my_secret_password_for_swap_test')
    const secretHashHex = hexToUint8Array(ethers.keccak256(stringBytes))
    // --------------------------------------------------------------------

    // Build the txn payload
    const payload = {
        type: 'entry_function_payload',
        function: `${profile_addr}::fusion_plus::create_order`,
        // 1) generic type functionArguments
        typeArguments: [SRC_COIN_TYPE],
        // 2) the four explicit Move parameters, IN ORDER, all as strings or hex
        functionArguments: [
            srcAmount.toString(), // u64
            minDstAmount.toString(), // u64
            expiresInSecs.toString(), // u64
            secretHashHex // vector<u8>  (hex string with 0x-prefix)
        ]
    }

    //   console.log("payload", payload);

    await signAndSubmit(payload)
}

async function fund_dst_escrow(): Promise<void> {
    // -------------- user-supplied values --------------------------------
    const dst_amount = 10_000
    // const expiration_duration_secs = Math.floor(Date.now() / 1000) + 3600
    const secret = ethers.toUtf8Bytes('my_secret_password_for_swap_test')
    const secret_hash = hexToUint8Array(ethers.keccak256(secret))

    const TimeLocks = {
        srcWithdrawal: 10, // 10sec finality lock
        srcPublicWithdrawal: 120, // 2min private withdrawal window
        srcCancellation: 121, // 1sec after public withdrawal
        srcPublicCancellation: 122, // 1sec private cancellation
        dstWithdrawal: 10, // 10sec finality lock
        dstPublicWithdrawal: 100, // 100sec private withdrawal
        dstCancellation: 101 // 1sec public withdrawal
    }
    // --------------------------------------------------------------------

    // Build the txn payload
    const payload = {
        function: `${profile_addr}::fusion_plus::fund_dst_escrow`,
        // 1) generic type functionArguments
        typeArguments: [SRC_COIN_TYPE],
        // 2) the four explicit Move parameters, IN ORDER, all as strings or hex
        functionArguments: [
            dst_amount.toString(),
            secret_hash,
            TimeLocks.srcWithdrawal,
            TimeLocks.srcPublicWithdrawal,
            TimeLocks.srcCancellation,
            TimeLocks.srcPublicCancellation,
            TimeLocks.dstWithdrawal,
            TimeLocks.dstPublicWithdrawal,
            TimeLocks.dstCancellation
        ]
    }

    // const payload = {
    //     function: '0xbf4897e1461fb38861f8431f68b1332d90dd62e3f0d454470b6fc9278dd8bccc::fusion_plus::fund_dst_escrow',
    //     typeArguments: [
    //         // Note: typeArguments instead of typeArguments
    //         '0xbf4897e1461fb38861f8431f68b1332d90dd62e3f0d454470b6fc9278dd8bccc::my_token::SimpleToken'
    //     ],
    //     functionArguments: [
    //         // Note: functionArguments instead of functionArguments
    //         '10000',
    //         [
    //             131, 21, 222, 58, 86, 31, 52, 71, 190, 13, 165, 188, 231, 193, 58, 91, 42, 5, 143, 177, 50, 158, 176,
    //             53, 59, 95, 66, 146, 195, 218, 68, 233
    //         ], // Convert to regular array
    //         10,
    //         120,
    //         121,
    //         122,
    //         10,
    //         100,
    //         101
    //     ]
    // }

    console.log('payload', payload)

    await signAndSubmit(payload)
}

async function claim_funds(): Promise<void> {
    // -------------- user-supplied values --------------------------------
    const order_id = 1
    //   const secretVec8 = hexToUint8Array(ethers.keccak256(secret));
    // --------------------------------------------------------------------

    // Build the txn payload
    const payload = {
        type: 'entry_function_payload',
        function: `${profile_addr}::fusion_plus::claim_funds`,
        // 1) generic type functionArguments
        typeArguments: [SRC_COIN_TYPE],
        // 2) the four explicit Move parameters, IN ORDER, all as strings or hex
        functionArguments: [order_id.toString(), secret]
    }

    //   console.log("payload", payload);

    await signAndSubmit(payload)
}

async function cancel_swap(): Promise<void> {
    // -------------- user-supplied values --------------------------------
    const order_id = 19
    // --------------------------------------------------------------------

    // Build the txn payload
    const payload = {
        type: 'entry_function_payload',
        function: `${profile_addr}::fusion_plus::cancel_swap`,
        // 1) generic type functionArguments
        typeArguments: [SRC_COIN_TYPE],
        // 2) the four explicit Move parameters, IN ORDER, all as strings or hex
        functionArguments: [order_id.toString()]
    }

    //   console.log("payload", payload);

    await signAndSubmit(payload)
}

async function signAndSubmit(payload: any): Promise<void> {
    console.log('payload', payload)
    let transaction
    let senderAuthenticator
    let pending
    try {
        transaction = await client.transaction.build.simple({sender: account.accountAddress, data: {...payload}})
        console.log('rawTxn', transaction)
    } catch (e) {
        console.error(e)
    }

    try {
        senderAuthenticator = client.transaction.sign({
            signer: account,
            transaction
        })
    } catch (e) {
        console.error(e)
    }

    try {
        pending = await client.transaction.submit.simple({
            transaction,
            senderAuthenticator
        })
        console.log('pending', pending)
    } catch (e) {
        console.error(e)
    }

    try {
        await client.waitForTransaction({transactionHash: pending.hash})
        console.log('✓ Txn:', `https://explorer.aptoslabs.com/txn/${pending.hash}?network=mainnet`)
    } catch (e) {
        console.error(e)
    }
}

;(async (): Promise<void> => {
    // First time setup for new contract deployment.
    // console.log('calling initialize_token')
    // await initialize_token()
    // console.log('calling initialize_ledger')
    // await initialize_ledger()
    // await register_token()
    // await mint_token()
    // When needed
    //   await anounce_order();
    // await fund_dst_escrow();
    // await claim_funds()
    // await cancel_swap()
})()

function hexToUint8Array(hex: string): Uint8Array {
    if (hex.startsWith('0x')) {
        hex = hex.substring(2)
    }

    if (hex.length % 2 !== 0) {
        throw new Error('Hex string must have an even number of characters for byte conversion.')
    }

    const byteArray = new Uint8Array(hex.length / 2)

    for (let i = 0; i < byteArray.length; i++) {
        byteArray[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16)
    }

    return byteArray
}

export {fund_dst_escrow, claim_funds, cancel_swap, anounce_order, initialize_ledger}
