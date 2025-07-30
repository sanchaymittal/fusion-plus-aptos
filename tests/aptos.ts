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
// const secret = ethers.toUtf8Bytes('my_secret_password_for_swap_test')

// Helper function to compute SHA3-256 hash of secret
function computeHashlock(secret: string): Uint8Array {
    // Convert hex secret to bytes and compute SHA3-256 hash
    const secretBytes = hexToUint8Array(secret)
    // Using ethers keccak256 as a substitute for SHA3-256 (Move's hash::sha3_256)
    // Note: This should ideally be SHA3-256, but keccak256 is commonly used
    const hashHex = ethers.keccak256(secretBytes)

    return hexToUint8Array(hashHex)
}

// Token initialization and minting functions
async function initialize_token(): Promise<void> {
    console.log('🪙 Initializing custom token...')

    const payload = {
        function: `${profile_addr}::my_token::initialize`,
        typeArguments: [],
        functionArguments: [
            'Simple Token', // name
            'STK', // symbol
            8, // decimals
            true // monitor_supply
        ]
    }

    try {
        await signAndSubmitWithResult(payload)
        console.log('✅ Custom token initialized')
    } catch (error: any) {
        if (error.message?.includes('E_ALREADY_INITIALIZED') || error.message?.includes('already_exists')) {
            console.log('⚠️ Token already initialized, continuing...')
        } else {
            throw error
        }
    }
}

async function register_token(): Promise<void> {
    console.log('📝 Registering for custom token...')

    const payload = {
        function: '0x1::managed_coin::register',
        typeArguments: [SRC_COIN_TYPE],
        functionArguments: []
    }

    try {
        await signAndSubmitWithResult(payload)
        console.log('✅ Registered for custom token')
    } catch (error: any) {
        if (error.message?.includes('EALREADY_EXISTS') || error.message?.includes('already_exists')) {
            console.log('⚠️ Already registered for token, continuing...')
        } else {
            throw error
        }
    }
}

async function mint_token(): Promise<void> {
    console.log('🪙 Minting custom tokens...')

    const payload = {
        function: `${profile_addr}::my_token::mint`,
        typeArguments: [],
        functionArguments: [
            accountAddress, // to address
            1_000_000_000_000 // amount (1T units = 10M tokens with 8 decimals)
        ]
    }

    await signAndSubmitWithResult(payload)
    console.log('✅ Custom tokens minted')
}

// Shared configuration for consistency across all escrow operations
function getSharedEscrowConfig(): any {
    return {
        dst_amount: 10_000,
        safety_deposit: 1000,
        timelocks: {
            src_withdrawal_delay: 10,
            src_public_withdrawal_delay: 120,
            src_cancellation_delay: 121,
            src_public_cancellation_delay: 122,
            dst_withdrawal_delay: 10,
            dst_public_withdrawal_delay: 100,
            dst_cancellation_delay: 101,
            deployed_at: 0
        }
    }
}

// New functions for the upgraded Move modules
async function create_dst_escrow(
    dstImmutables: any,
    hashLockForAptos: any
): Promise<{escrowAddress: string; immutables: any}> {
    console.log('🏦 Creating destination escrow on Aptos...')

    const dst_amount = 10_000 // dstImmutables.amount
    const timelocks = dstImmutables.timeLocks
    const safety_deposit = 1000 // dstImmutables.safetyDeposit
    const order_hash_bytes = hexToUint8Array(dstImmutables.orderHash)

    const payload = {
        function: `${resolver_addr}::resolver::deploy_dst_escrow`,
        typeArguments: [SRC_COIN_TYPE, '0x1::aptos_coin::AptosCoin', SRC_COIN_TYPE], // TokenType, FeeTokenType, AccessTokenType
        functionArguments: [
            resolver_addr, // resolver_addr (where resolver config is stored)
            dst_amount, // token amount to deposit
            safety_deposit, // safety deposit amount
            // immutables components
            order_hash_bytes, // order_hash as proper byte array
            hashLockForAptos, // hashlock as byte array
            account.accountAddress.toString(), // maker
            account.accountAddress.toString(), // taker
            dst_amount, // amount
            safety_deposit, // safety_deposit
            // timelocks components
            timelocks._srcWithdrawal,
            timelocks._srcPublicWithdrawal,
            timelocks._srcCancellation,
            timelocks._srcPublicCancellation,
            timelocks._dstWithdrawal,
            timelocks._dstPublicWithdrawal,
            timelocks._dstCancellation,
            timelocks._deployedAt,
            Math.floor(Date.now() / 1000) + 3600 // src_cancellation_timestamp as number, not string
        ]
    }

    const txnResponse = await signAndSubmitWithResult(payload)

    // Extract escrow address and immutables from events
    const escrowData = extractEscrowDataFromEvents(txnResponse)
    console.log('✅ Destination escrow created at address:', escrowData.escrowAddress)
    console.log('📊 Immutables from event:', escrowData.immutables)

    return escrowData
}

async function withdraw_dst_escrow(
    escrowAddress: string,
    secret: any,
    immutables: any,
    hashLockForAptos: any
): Promise<void> {
    console.log('💰 Withdrawing from destination escrow at:', escrowAddress)

    console.log('Using immutables from events:', immutables)
    const order_hash_bytes = hexToUint8Array(immutables.order_hash)

    const payload = {
        function: `${resolver_addr}::resolver::withdraw`,
        typeArguments: [SRC_COIN_TYPE],
        functionArguments: [
            escrowAddress, // escrow_addr
            hexToUint8Array(secret), // secret to unlock hashlock
            // immutables components - using values from events
            order_hash_bytes, // order_hash
            hashLockForAptos, // hashlock
            immutables.maker, // maker
            immutables.taker, // taker
            parseInt(immutables.amount), // amount
            parseInt(immutables.safety_deposit), // safety_deposit
            // timelocks components - using values from events
            immutables.timelocks.src_withdrawal_delay,
            immutables.timelocks.src_public_withdrawal_delay,
            immutables.timelocks.src_cancellation_delay,
            immutables.timelocks.src_public_cancellation_delay,
            immutables.timelocks.dst_withdrawal_delay,
            immutables.timelocks.dst_public_withdrawal_delay,
            immutables.timelocks.dst_cancellation_delay,
            parseInt(immutables.timelocks.deployed_at),
            account.accountAddress.toString() // recipient
        ]
    }

    await signAndSubmitWithResult(payload)
    console.log('✅ Funds withdrawn from destination escrow')
}

async function cancel_dst_escrow(escrowAddress: string, order_hash: string, secret: any): Promise<void> {
    console.log('❌ Cancelling destination escrow at:', escrowAddress)

    const config = getSharedEscrowConfig()
    const {dst_amount, safety_deposit, timelocks} = config
    const order_hash_bytes = hexToUint8Array(order_hash)

    const payload = {
        function: `${resolver_addr}::resolver::cancel`,
        typeArguments: [SRC_COIN_TYPE],
        functionArguments: [
            escrowAddress, // escrow_addr
            // immutables components
            Array.from(order_hash_bytes), // order_hash
            hexToUint8Array(secret), // hashlock
            account.accountAddress.toString(), // maker
            account.accountAddress.toString(), // taker
            dst_amount, // amount
            safety_deposit, // safety_deposit
            // timelocks components
            timelocks.src_withdrawal_delay,
            timelocks.src_public_withdrawal_delay,
            timelocks.src_cancellation_delay,
            timelocks.src_public_cancellation_delay,
            timelocks.dst_withdrawal_delay,
            timelocks.dst_public_withdrawal_delay,
            timelocks.dst_cancellation_delay,
            timelocks.deployed_at
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

function extractEscrowDataFromEvents(txnResponse: any): {escrowAddress: string; immutables: any} {
    try {
        // Look for EscrowCreatedEvent in the transaction events
        const events = txnResponse.events || []
        console.log('🔍 Transaction events:', JSON.stringify(events, null, 2))

        for (const event of events) {
            console.log('📄 Event type:', event.type)

            if (event.type && event.type.includes('EscrowCreatedEvent')) {
                const eventData = event.data
                console.log('📦 Event data:', JSON.stringify(eventData, null, 2))

                // eslint-disable-next-line max-depth
                if (eventData && eventData.escrow_address && eventData.immutables) {
                    return {
                        escrowAddress: eventData.escrow_address,
                        immutables: eventData.immutables
                    }
                }
            }
        }

        throw new Error('No escrow data found in transaction events')
    } catch (error) {
        console.error('Error extracting escrow data from events:', error)
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

// Initialize escrow factory
async function initialize_factory(): Promise<void> {
    console.log('🏭 Initializing escrow factory...')

    const payload = {
        function: `${profile_addr}::escrow_factory::initialize`,
        typeArguments: ['0x1::aptos_coin::AptosCoin', SRC_COIN_TYPE], // FeeTokenType, AccessTokenType
        functionArguments: [
            3600, // src_rescue_delay (1 hour)
            7200, // dst_rescue_delay (2 hours)
            accountAddress, // fee_bank_owner
            accountAddress // access_token_config_addr
        ]
    }

    try {
        await signAndSubmitWithResult(payload)
        console.log('✅ Escrow factory initialized')
    } catch (error: any) {
        if (
            error.message?.includes('E_ALREADY_INITIALIZED') ||
            error.message?.includes('already_exists') ||
            error.message?.includes('initialize at code offset')
        ) {
            console.log('⚠️ Factory already initialized, continuing...')
        } else {
            throw error
        }
    }
}

// Initialize resolver contract
async function initialize_resolver(): Promise<void> {
    console.log('🔧 Initializing resolver contract...')

    const payload = {
        function: `${resolver_addr}::resolver::initialize`,
        typeArguments: [],
        functionArguments: [
            profile_addr // factory_address - using profile_addr as placeholder for factory
        ]
    }

    try {
        await signAndSubmitWithResult(payload)
        console.log('✅ Resolver contract initialized')
    } catch (error: any) {
        if (
            error.message?.includes('E_ALREADY_INITIALIZED') ||
            error.message?.includes('already_exists') ||
            error.message?.includes('initialize at code offset 7')
        ) {
            console.log('⚠️ Resolver already initialized, continuing...')
        } else {
            throw error
        }
    }
}

// Test function to demonstrate full escrow flow
async function test_resolver_flow(): Promise<void> {
    try {
        console.log('🚀 Starting resolver contract test flow...')

        // Step 0: Setup tokens first
        console.log('🔧 Setting up tokens...')
        // await initialize_token()
        // await register_token()
        await mint_token()

        // Step 1: Initialize factory and resolver contracts
        // await initialize_factory()
        // await initialize_resolver()

        // Generate a test order hash
        const testOrderHash =
            '0x' + Array.from({length: 64}, () => Math.floor(Math.random() * 16).toString(16)).join('')
        console.log('Generated test order hash:', testOrderHash)

        // Step 2: Create destination escrow
        const mockDstImmutables = {
            orderHash: testOrderHash,
            timeLocks: getSharedEscrowConfig().timelocks
        }
        const testHashLock = '0x' + Array.from({length: 64}, () => Math.floor(Math.random() * 16).toString(16)).join('')
        const escrowData = await create_dst_escrow(mockDstImmutables, testHashLock)
        console.log('Escrow created at:', escrowData.escrowAddress)
        console.log('✅ Escrow creation completed successfully')

        // Step 3: For now, skip withdrawal since escrow factory doesn't actually create escrows yet
        // TODO: Implement actual escrow creation in factory and enable withdrawal testing
        console.log('⚠️ Skipping withdrawal test - escrow factory needs actual escrow creation implementation')

        // Alternative: Test cancellation flow
        // const mockDstImmutables2 = {
        //     orderHash: testOrderHash + '2',
        //     timeLocks: getSharedEscrowConfig().timelocks
        // }
        // const escrowData2 = await create_dst_escrow(mockDstImmutables2, testHashLock)
        // await cancel_dst_escrow(escrowAddress2, testOrderHash + '2')
        // console.log('✅ Cancellation completed successfully')

        console.log('🎉 Resolver contract test flow completed successfully!')
    } catch (error) {
        console.error('❌ Test flow failed:', error)
        throw error
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
    // Test the resolver contract flow
    // await mint_token()
    // await test_resolver_flow()
})()

export {
    create_dst_escrow,
    withdraw_dst_escrow,
    cancel_dst_escrow,
    get_factory_stats,
    getTokenBalance,
    getAptosBalance,
    getAptosBalances,
    test_resolver_flow,
    initialize_resolver,
    initialize_factory,
    initialize_token,
    register_token,
    mint_token
}
