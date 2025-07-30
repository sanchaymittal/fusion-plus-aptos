import {Account, Aptos, AptosConfig, Network, NetworkToNetworkName, Ed25519PrivateKey} from '@aptos-labs/ts-sdk'
import * as dotenv from 'dotenv'
import {ethers} from 'ethers'

dotenv.config()

const privateKey = new Ed25519PrivateKey(process.env.DEPLOYER_PRIVATE_KEY as string)
const account = Account.fromPrivateKey({privateKey})
const accountAddress = account.accountAddress.toString()

const makerPrivateKey = new Ed25519PrivateKey(process.env.MAKER_PRIVATE_KEY as string)
const makerAccount = Account.fromPrivateKey({privateKey: makerPrivateKey})
const makerAddress = makerAccount.accountAddress.toString()

// Default to devnet, but allow for overriding
const APTOS_NETWORK: Network = NetworkToNetworkName[process.env.APTOS_NETWORK ?? Network.DEVNET]
// const APTOS_NETWORK: Network = NetworkToNetworkName[NODE];
const config = new AptosConfig({network: APTOS_NETWORK})
const client = new Aptos(config)
const profile_addr = accountAddress
const resolver_addr = accountAddress
const SRC_COIN_TYPE = `${profile_addr}::my_token::SimpleToken`
const secret = ethers.toUtf8Bytes('my_secret_password_for_swap_test')

// New functions for the upgraded Move modules
async function create_dst_escrow(order_hash: string): Promise<string> {
    console.log('🏦 Creating destination escrow on Aptos...')

    const dst_amount = 10_000

    // Create timelocks configuration
    const timelocks = {
        src_withdrawal_delay: 10,
        src_public_withdrawal_delay: 120,
        src_cancellation_delay: 121,
        src_public_cancellation_delay: 122,
        dst_withdrawal_delay: 10,
        dst_public_withdrawal_delay: 100,
        dst_cancellation_delay: 101,
        deployed_at: Math.floor(Date.now() / 1000)
    }

    // Convert order_hash to proper byte array
    const order_hash_bytes = hexToUint8Array(order_hash)
    console.log('Order hash bytes length:', order_hash_bytes.length)
    console.log('Secret bytes length:', secret.length)

    const payload = {
        function: `${resolver_addr}::resolver::deploy_dst_escrow`,
        typeArguments: [SRC_COIN_TYPE, '0x1::aptos_coin::AptosCoin', SRC_COIN_TYPE], // TokenType, FeeTokenType, AccessTokenType
        functionArguments: [
            resolver_addr, // resolver_addr (where resolver config is stored)
            dst_amount, // token amount to deposit
            1000, // safety deposit amount
            // immutables components
            Array.from(order_hash_bytes), // order_hash as proper byte array
            Array.from(secret), // hashlock as byte array
            account.accountAddress.toString(), // maker
            account.accountAddress.toString(), // taker
            Array.from(new TextEncoder().encode(SRC_COIN_TYPE)), // token_type as bytes
            dst_amount, // amount
            1000, // safety_deposit
            // timelocks components
            timelocks.src_withdrawal_delay,
            timelocks.src_public_withdrawal_delay,
            timelocks.src_cancellation_delay,
            timelocks.src_public_cancellation_delay,
            timelocks.dst_withdrawal_delay,
            timelocks.dst_public_withdrawal_delay,
            timelocks.dst_cancellation_delay,
            timelocks.deployed_at,
            Math.floor(Date.now() / 1000) + 3600 // src_cancellation_timestamp as number, not string
        ]
    }

    const txnResponse = await signAndSubmitWithResult(payload)

    // Extract escrow address from events
    const escrowAddress = extractEscrowAddressFromEvents(txnResponse)
    console.log('✅ Destination escrow created at address:', escrowAddress)

    return escrowAddress
}

async function withdraw_dst_escrow(escrowAddress: string): Promise<void> {
    console.log('💰 Withdrawing from destination escrow at:', escrowAddress)

    const payload = {
        function: `${profile_addr}::escrow_core::withdraw`,
        typeArguments: [SRC_COIN_TYPE],
        functionArguments: [
            escrowAddress, // escrow_address from creation event
            secret, // secret to unlock hashlock
            account.accountAddress.toString() // recipient
        ]
    }

    await signAndSubmitWithResult(payload)
    console.log('✅ Funds withdrawn from destination escrow')
}

async function cancel_dst_escrow(): Promise<void> {
    console.log('❌ Cancelling destination escrow...')

    const payload = {
        function: `${profile_addr}::escrow_core::cancel`,
        typeArguments: [SRC_COIN_TYPE],
        functionArguments: [
            account.accountAddress.toString(), // escrow_address
            account.accountAddress.toString() // recipient
        ]
    }

    await signAndSubmitWithResult(payload)
    console.log('✅ Destination escrow cancelled')
}

async function get_factory_stats(): Promise<void> {
    console.log('📊 Getting factory statistics...')

    try {
        // This would be a view function call to get factory stats
        // For now, just log that we're getting stats
        console.log('Factory stats retrieved')
    } catch (error) {
        console.error('Error getting factory stats:', error)
    }
}

async function getTokenBalance(address: string, tokenType: string = SRC_COIN_TYPE): Promise<bigint> {
    try {
        const resources = await client.getAccountResources({accountAddress: address})

        // Look for the coin store resource for the specific token type
        const coinStoreType = `0x1::coin::CoinStore<${tokenType}>`
        const coinStore = resources.find((resource) => resource.type === coinStoreType)

        if (coinStore && coinStore.data) {
            const data = coinStore.data as any

            return BigInt(data.coin.value || '0')
        }

        return BigInt(0)
    } catch (error) {
        console.error(`Error getting token balance for ${address}:`, error)

        return BigInt(0)
    }
}

async function getAptosBalance(address: string): Promise<bigint> {
    try {
        const resources = await client.getAccountResources({accountAddress: address})

        // Look for APT coin store
        const coinStoreType = '0x1::coin::CoinStore<0x1::aptos_coin::AptosCoin>'
        const coinStore = resources.find((resource) => resource.type === coinStoreType)

        if (coinStore && coinStore.data) {
            const data = coinStore.data as any

            return BigInt(data.coin.value || '0')
        }

        return BigInt(0)
    } catch (error) {
        console.error(`Error getting APT balance for ${address}:`, error)
        return BigInt(0)
    }
}

async function getAptosBalances(): Promise<{user: bigint; resolver: bigint}> {
    const userBalance = await getTokenBalance(account.accountAddress.toString())
    const resolverBalance = await getTokenBalance(account.accountAddress.toString()) // Using same account as placeholder for resolver

    return {
        user: userBalance,
        resolver: resolverBalance
    }
}

async function signAndSubmitWithResult(payload: any): Promise<any> {
    console.log('payload', payload)
    let transaction
    let senderAuthenticator
    let pending
    try {
        transaction = await client.transaction.build.simple({sender: account.accountAddress, data: {...payload}})
        console.log('rawTxn', transaction)
    } catch (e) {
        console.error(e)
        throw e
    }

    try {
        senderAuthenticator = client.transaction.sign({
            signer: account,
            transaction
        })
    } catch (e) {
        console.error(e)
        throw e
    }

    try {
        pending = await client.transaction.submit.simple({
            transaction,
            senderAuthenticator
        })
        console.log('pending', pending)
    } catch (e) {
        console.error(e)
        throw e
    }

    try {
        const txnResult = await client.waitForTransaction({transactionHash: pending.hash})
        console.log('✓ Txn:', `https://explorer.aptoslabs.com/txn/${pending.hash}?network=mainnet`)

        return txnResult
    } catch (e) {
        console.error(e)
        throw e
    }
}

function extractEscrowAddressFromEvents(txnResponse: any): string {
    try {
        // Look for DstEscrowCreatedEvent in the transaction events
        const events = txnResponse.events || []

        for (const event of events) {
            if (event.type && event.type.includes('DstEscrowCreatedEvent')) {
                const eventData = event.data

                // eslint-disable-next-line max-depth
                if (eventData && eventData.escrow_address) {
                    return eventData.escrow_address
                }
            }
        }

        throw new Error('DstEscrowCreatedEvent not found in transaction events')
    } catch (error) {
        console.error('Error extracting escrow address from events:', error)
        throw error
    }
}

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

export {
    create_dst_escrow,
    withdraw_dst_escrow,
    cancel_dst_escrow,
    get_factory_stats,
    getTokenBalance,
    getAptosBalance,
    getAptosBalances
}
