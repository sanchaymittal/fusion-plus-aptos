import {Account, Aptos, AptosConfig, Network, NetworkToNetworkName, Ed25519PrivateKey} from '@aptos-labs/ts-sdk'
import * as dotenv from 'dotenv'
import {ethers} from 'ethers'

dotenv.config()

// Transaction tracking for demo purposes
export const aptosTransactions: Array<{
    hash: string
    type: string
    description: string
    timestamp: number
    explorerUrl: string
}> = []

// Use the friday profile private key
const privateKey = new Ed25519PrivateKey('0xe28ab8471b770f5f3819e901177b41bec8908e5edd61a2c4b5c5ee1b314d4839')
const account = Account.fromPrivateKey({privateKey})
const accountAddress = account.accountAddress.toString()

// Use the same account for maker transactions for now
const makerPrivateKey = new Ed25519PrivateKey('0xe28ab8471b770f5f3819e901177b41bec8908e5edd61a2c4b5c5ee1b314d4839')
const makerAccount = Account.fromPrivateKey({privateKey: makerPrivateKey})
const makerAddress = makerAccount.accountAddress.toString()

// Default to devnet, but allow for overriding
const APTOS_NETWORK: Network = NetworkToNetworkName[process.env.APTOS_NETWORK ?? Network.DEVNET]
// const APTOS_NETWORK: Network = NetworkToNetworkName[NODE];
const config = new AptosConfig({network: APTOS_NETWORK})
const client = new Aptos(config)
const profile_addr = '0xdef391b1c8951bf801f67a005f9eba70a5aae6d02eba6bb4889a88288ea806a2'
const resolver_addr = profile_addr
const SRC_COIN_TYPE = `${profile_addr}::my_token::SimpleToken`
// const secret = ethers.toUtf8Bytes('my_secret_password_for_swap_test')

// Aptos equivalent of signOrder - using Ed25519 signing for Aptos compatibility
async function signOrderAptos(order: any, chainId: number): Promise<string> {
    // Create the order data structure similar to EIP-712 but for Aptos
    const orderData = {
        salt: order.salt,
        maker: order.maker,
        receiver: order.receiver || order.maker,
        makerAsset: order.makerAsset,
        takerAsset: order.takerAsset,
        makingAmount: order.makingAmount,
        takingAmount: order.takingAmount,
        makerTraits: order.makerTraits || 0
    }

    // Serialize the order data for signing
    const orderString = JSON.stringify({
        chainId,
        order: orderData
    })

    // Sign using Ed25519 (Aptos native signature scheme)
    const messageBytes = new TextEncoder().encode(orderString)
    const signature = makerAccount.sign(messageBytes)

    return signature.toString()
}

// Compute escrow address using Aptos CREATE2-like pattern
function computeEscrowAddress(factoryAddr: string, orderHash: string, implType: number = 0): string {
    // Based on create2.move implementation:
    // 1. Combine factory address + salt (order hash) + implementation type
    // 2. Hash with SHA3-256
    // 3. Use first 32 bytes as address

    // For now, use a simplified deterministic computation
    // In production, this would match the exact Move create2::compute_address logic
    const seed = `${factoryAddr}-${orderHash}-${implType}`
    const hash = ethers.keccak256(ethers.toUtf8Bytes(seed))

    // Aptos addresses are 32 bytes (64 hex chars)
    return hash.slice(0, 66) // 0x + 64 chars
}

// Create source escrow on Aptos (for Aptos -> Ethereum swaps)
async function create_src_escrow(
    order: any,
    hashLockForAptos: any,
    dstChainId: number,
    dstToken: string
): Promise<{escrowAddress: string; immutables: any}> {
    console.log('🏦 Creating source escrow on Aptos...')

    const src_amount = 1 // Test with minimal amount
    const timelocks = order.timeLocks || getSharedEscrowConfig().timelocks
    const src_safety_deposit = 10 // Source chain safety deposit
    const dst_safety_deposit = 5 // Destination chain safety deposit
    const order_hash_bytes = hexToUint8Array(order.orderHash)

    // Encode both deposits into a single u128 value (src_safety_deposit in upper 64 bits, dst_safety_deposit in lower 64 bits)
    // Note: Each deposit must fit in u64 (max value: 18,446,744,073,709,551,615)
    // const combined_deposits = (BigInt(src_safety_deposit) << 64n) | BigInt(dst_safety_deposit)

    // The contract withdraws tokens from the caller's account, so mint to user account
    const totalTokensNeeded = src_amount + src_safety_deposit // Only need src_safety_deposit for APT

    // Check user account balance before calling the function
    console.log('🔍 Checking account balance before escrow creation...')
    await checkAccountAndBalances()

    // If no tokens, try minting some
    const currentBalance = await getTokenBalance(accountAddress, SRC_COIN_TYPE)
    if (currentBalance < BigInt(src_amount)) {
        console.log(`💰 Insufficient tokens (${currentBalance}), minting more...`)
        await mint_token()
        console.log('🔍 Balance after minting:')
        await checkAccountAndBalances()
    }

    const payload = {
        function: `${resolver_addr}::resolver::deploy_src_escrow`,
        typeArguments: [SRC_COIN_TYPE, '0x1::aptos_coin::AptosCoin', SRC_COIN_TYPE], // TokenType, FeeTokenType, AccessTokenType
        functionArguments: [
            resolver_addr, // resolver_addr (where resolver config is stored)
            // Order data components
            order_hash_bytes, // order_hash as proper byte array
            account.accountAddress.toString(), // maker
            account.accountAddress.toString(), // receiver
            SRC_COIN_TYPE, // maker_asset (string)
            'ETH_USDC', // taker_asset (string)
            src_amount, // making_amount (1)
            src_amount, // taking_amount (1)
            // Escrow args components
            hashLockForAptos, // hashlock_info as byte array
            dstChainId, // dst_chain_id
            dstToken, // dst_token (string)
            0, // deposits as u128 (src_safety_deposit << 64 | dst_safety_deposit)
            // Timelocks components (all u32)
            timelocks._srcWithdrawal || timelocks.src_withdrawal_delay || 10,
            timelocks._srcPublicWithdrawal || timelocks.src_public_withdrawal_delay || 120,
            timelocks._srcCancellation || timelocks.src_cancellation_delay || 121,
            timelocks._srcPublicCancellation || timelocks.src_public_cancellation_delay || 122,
            timelocks._dstWithdrawal || timelocks.dst_withdrawal_delay || 10,
            timelocks._dstPublicWithdrawal || timelocks.dst_public_withdrawal_delay || 100,
            timelocks._dstCancellation || timelocks.dst_cancellation_delay || 101,
            // Auction config components
            56, // gas_bump_estimate (u32)
            1000, // gas_price_estimate (u32)
            Math.floor(Date.now() / 1000), // start_time (u32)
            3600, // duration (u32)
            0, // initial_rate_bump (u32)
            // Taker data components (for Merkle proofs)
            [], // proof (vector<vector<u8>>)
            0, // idx (u64)
            hashLockForAptos // secret_hash (vector<u8>)
        ]
    }

    const txnResponse = await signAndSubmitWithResult(payload)

    // Extract escrow address and immutables from events
    const escrowData = extractEscrowDataFromEvents(txnResponse)
    console.log('✅ Source escrow created at address:', escrowData.escrowAddress)
    console.log('📊 Immutables from event:', escrowData.immutables)

    return escrowData
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
        const initTxResult = await signAndSubmitWithResult(payload)
        console.log('✅ Custom token initialized')
        console.log('🔍 Token initialization transaction hash:', initTxResult.hash)
    } catch (error: any) {
        console.log('❌ Token initialization error:', error.message)
        if (error.message?.includes('E_ALREADY_INITIALIZED') || error.message?.includes('already_exists')) {
            console.log('⚠️ Token already initialized, continuing...')
        } else {
            console.log('🔍 Full initialization error:', error)
            throw error
        }
    }
}

async function register_token(): Promise<void> {
    console.log('📝 Registering for custom token...')

    // Use Aptos framework's direct registration instead of custom function
    const payload = {
        function: '0x1::coin::register',
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

async function transfer_tokens(to: string, amount: number): Promise<void> {
    console.log(`💸 Transferring ${amount} custom tokens to ${to}...`)

    const payload = {
        function: `${profile_addr}::my_token::transfer`,
        typeArguments: [],
        functionArguments: [
            to, // recipient address
            amount // amount to transfer
        ]
    }

    await signAndSubmitWithResult(payload)
    console.log('✅ Custom tokens transferred')
}

async function checkAccountAndBalances(): Promise<void> {
    console.log('🔍 Account and Balance Information:')
    console.log(`   Account Address: ${accountAddress}`)
    console.log(`   Profile Address: ${profile_addr}`)
    console.log(`   Resolver Address: ${resolver_addr}`)
    console.log(`   Custom Token Type: ${SRC_COIN_TYPE}`)

    const customTokenBalance = await getTokenBalance(accountAddress, SRC_COIN_TYPE)
    const aptBalance = await getAptosBalance(accountAddress)

    console.log('📊 Current Balances:')
    console.log(`   Custom Token Balance: ${customTokenBalance}`)
    console.log(`   APT Balance: ${aptBalance} octas (${Number(aptBalance) / 100_000_000} APT)`)
}

async function checkBalancesAndRequirements(
    srcAmount: number,
    safetyDeposit: number
): Promise<{sufficient: boolean; details: any}> {
    console.log('🔍 Checking token balances and requirements...')

    const customTokenBalance = await getTokenBalance(accountAddress, SRC_COIN_TYPE)
    const aptBalance = await getAptosBalance(accountAddress)

    const totalRequired = srcAmount + safetyDeposit

    console.log('📊 Balance Check Results:')
    console.log(`   Custom Token (${SRC_COIN_TYPE}):`)
    console.log(`     Available: ${customTokenBalance}`)
    console.log(`     Required: ${totalRequired} (${srcAmount} + ${safetyDeposit} safety deposit)`)
    console.log(`     Sufficient: ${customTokenBalance >= BigInt(totalRequired) ? '✅' : '❌'}`)

    console.log(`   APT Balance: ${aptBalance} octas (${Number(aptBalance) / 100_000_000} APT)`)

    const sufficient = customTokenBalance >= BigInt(totalRequired)

    if (!sufficient) {
        console.log(`❌ INSUFFICIENT TOKENS!`)
        console.log(`   Need ${totalRequired - Number(customTokenBalance)} more custom tokens`)
    } else {
        console.log(`✅ Sufficient tokens available`)
    }

    return {
        sufficient,
        details: {
            customTokenBalance: Number(customTokenBalance),
            aptBalance: Number(aptBalance),
            totalRequired,
            shortfall: sufficient ? 0 : totalRequired - Number(customTokenBalance)
        }
    }
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

        // Debug: Log all resources first
        console.log(`🔍 Found ${resources.length} total resources for address ${address}`)

        // Debug: Log all coin store resources
        const coinStores = resources.filter((r) => r.type.includes('coin::CoinStore'))
        console.log(`🔍 Found ${coinStores.length} coin stores for address ${address}:`)
        coinStores.forEach((store) => console.log(`  - ${store.type}`))

        // Debug: Look for any resources related to our token
        const tokenRelated = resources.filter((r) => r.type.includes('my_token') || r.type.includes('SimpleToken'))
        console.log(`🔍 Found ${tokenRelated.length} token-related resources:`)
        tokenRelated.forEach((resource) => console.log(`  - ${resource.type}`))

        // Look for the coin store resource for the specific token type
        const coinStoreType = `0x1::coin::CoinStore<${tokenType}>`
        console.log(`🔍 Looking for coin store type: ${coinStoreType}`)
        const coinStore = resources.find((resource) => resource.type === coinStoreType)

        if (coinStore && coinStore.data) {
            const data = coinStore.data as any
            console.log(`✅ Found coin store with data:`, data)
            return BigInt(data.coin.value || '0')
        } else {
            console.log(`❌ No coin store found for token type: ${tokenType}`)
            return BigInt(0)
        }
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
        const networkName =
            APTOS_NETWORK === Network.MAINNET ? 'mainnet' : APTOS_NETWORK === Network.TESTNET ? 'testnet' : 'devnet'
        const explorerUrl = `https://explorer.aptoslabs.com/txn/${pending.hash}?network=${networkName}`
        console.log('✓ Txn:', explorerUrl)

        // Track transaction for final summary
        const functionName = payload.function || 'unknown'
        let txType = 'Transaction'
        let description = `Function: ${functionName}`
        
        // Determine transaction type and description based on function
        if (functionName.includes('deploy_src_escrow')) {
            txType = 'Source Escrow Creation'
            description = 'Created source escrow on Aptos for cross-chain swap'
        } else if (functionName.includes('deploy_dst_escrow')) {
            txType = 'Destination Escrow Creation'
            description = 'Created destination escrow on Aptos for token deposit'
        } else if (functionName.includes('withdraw')) {
            txType = 'Token Withdrawal'
            description = 'Withdrew tokens from Aptos escrow'
        } else if (functionName.includes('cancel')) {
            txType = 'Escrow Cancellation'
            description = 'Cancelled Aptos escrow and recovered funds'
        } else if (functionName.includes('mint')) {
            txType = 'Token Minting'
            description = 'Minted custom tokens on Aptos'
        } else if (functionName.includes('initialize')) {
            txType = 'Contract Initialization'
            description = `Initialized ${functionName.includes('token') ? 'token' : functionName.includes('factory') ? 'factory' : 'resolver'} contract`
        }
        
        aptosTransactions.push({
            hash: pending.hash,
            type: txType,
            description,
            timestamp: Date.now(),
            explorerUrl
        })

        // Check transaction success status
        if (txnResult.success) {
            console.log('✅ Transaction executed successfully')
        } else {
            console.log('❌ Transaction failed during execution')
            console.log('🔍 VM status:', txnResult.vm_status)
            if (txnResult.events) {
                console.log('🔍 Events:', txnResult.events)
            }
        }

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
        typeArguments: [SRC_COIN_TYPE, SRC_COIN_TYPE], // FeeTokenType, AccessTokenType
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
            error.message?.includes('initialize at code offset') ||
            error.message?.includes('MoveToGeneric')
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
            error.message?.includes('initialize at code offset 7') ||
            error.message?.includes('MoveTo')
        ) {
            console.log('⚠️ Resolver already initialized, continuing...')
        } else {
            throw error
        }
    }
}

// Test function following the working test pattern for Aptos -> Ethereum USDC swap
async function test_aptos_to_eth_swap(): Promise<any> {
    try {
        console.log('🚀 Starting Aptos -> Ethereum USDC swap test...')

        // Step 1: Check balances before swap
        console.log('\n📊 Initial balance check:')
        await checkAccountAndBalances()

        // Step 2: Generate cryptographically secure secret for hashlock
        const secret_array = new Uint8Array(32)
        crypto.getRandomValues(secret_array)
        const secret = Array.from(secret_array)
            .map((b) => b.toString(16).padStart(2, '0'))
            .join('')

        // Generate SHA3-256 hash for Aptos (similar to working test)
        const hashLockForAptos = Array.from(secret_array) // Use raw bytes for Aptos

        console.log('🔐 Generated secret and hashlock')

        // Step 3: Create Aptos order (following working test pattern)
        const aptosOrder = {
            salt: Math.floor(Math.random() * 1000000).toString(),
            maker: accountAddress,
            receiver: accountAddress,
            makerAsset: SRC_COIN_TYPE, // Aptos custom token
            takerAsset: 'ETH_USDC', // Ethereum USDC (placeholder)
            makingAmount: '1000', // 1,000 custom tokens (with 8 decimals)
            takingAmount: '990', // 990 USDC equivalent (with 6 decimals)
            makerTraits: 0,
            orderHash: '0x' + Array.from({length: 64}, () => Math.floor(Math.random() * 16).toString(16)).join(''),
            timeLocks: {
                _srcWithdrawal: 10,
                _srcPublicWithdrawal: 120,
                _srcCancellation: 121,
                _srcPublicCancellation: 122,
                _dstWithdrawal: 10,
                _dstPublicWithdrawal: 100,
                _dstCancellation: 101
            },
            safetyDeposit: 100
        }

        console.log('📋 Created Aptos order:', aptosOrder.orderHash)

        // Step 4: Sign order using Aptos signature scheme
        const signature = await signOrderAptos(aptosOrder, 1) // Using chainId 1 for Aptos
        console.log('✍️ Order signed successfully')

        // Step 5: Create source escrow on Aptos
        console.log('\n🏦 Creating source escrow on Aptos...')
        const {escrowAddress: srcEscrowAddress, immutables: srcImmutables} = await create_src_escrow(
            aptosOrder,
            hashLockForAptos,
            11155111, // Ethereum Sepoli testnet chain ID
            '0x' + '0'.repeat(40) // Placeholder Ethereum USDC address
        )

        console.log(`✅ Source escrow created at: ${srcEscrowAddress}`)
        console.log('📊 Source escrow immutables:', srcImmutables)

        // Step 6: Check balances after escrow creation
        console.log('\n📊 Post-escrow balance check:')
        await checkAccountAndBalances()

        console.log('\n🎉 Aptos -> Ethereum swap test completed successfully!')
        console.log('📝 Next steps would be:')
        console.log('   1. Resolver creates destination escrow on Ethereum')
        console.log('   2. User withdraws USDC from Ethereum escrow')
        console.log('   3. Resolver withdraws Aptos tokens from source escrow')

        return {
            srcEscrowAddress,
            srcImmutables,
            secret,
            hashLockForAptos,
            order: aptosOrder
        }
    } catch (error) {
        console.error('❌ Aptos -> Ethereum swap test failed:', error)
        throw error
    }
}

;(async (): Promise<void> => {
    console.log('🚀 Starting comprehensive setup with proper token flow...')

    try {
        // // Step 1: Check current account and balances
        // await checkAccountAndBalances()
        // // Step 2: Token setup (only if needed)
        // console.log('\n🔧 Token Setup Phase:')
        // await initialize_token()
        // await register_token()
        // await mint_token()
        // // Step 3: Check balances after minting
        // console.log('\n📊 Post-mint balance check:')
        // await checkAccountAndBalances()
        // Step 4: No approval needed - resolver withdraws directly from user account
        // Step 5: Factory and resolver initialization
        // console.log('\n🏭 Contract Initialization Phase:')
        // await initialize_factory() // Now uses SRC_COIN_TYPE for both fee and access tokens
        // await initialize_resolver()
        // console.log('\n✅ All setup completed successfully!')
        // console.log('🎯 Ready for escrow operations')
        // Optional: Run test flow
        // await test_aptos_to_eth_swap()
    } catch (error) {
        // console.error('❌ Setup failed:', error)
    }
})()

// Function to get all Aptos transactions for final summary
export function getAptosTransactionSummary(): Array<{
    hash: string
    type: string
    description: string
    timestamp: number
    explorerUrl: string
}> {
    return aptosTransactions
}

// Function to clear transaction history (for testing)
export function clearAptosTransactions(): void {
    aptosTransactions.length = 0
}

export {
    create_dst_escrow,
    create_src_escrow,
    signOrderAptos,
    withdraw_dst_escrow,
    cancel_dst_escrow,
    get_factory_stats,
    getTokenBalance,
    getAptosBalance,
    getAptosBalances,
    test_aptos_to_eth_swap,
    initialize_resolver,
    initialize_factory,
    initialize_token,
    register_token,
    mint_token,
    transfer_tokens,
    computeEscrowAddress,
    checkAccountAndBalances,
    checkBalancesAndRequirements
}
