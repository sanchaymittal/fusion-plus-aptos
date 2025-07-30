import {Account, Aptos, AptosConfig, Network, NetworkToNetworkName, Ed25519PrivateKey} from '@aptos-labs/ts-sdk'
import * as dotenv from 'dotenv'

dotenv.config()

// Configuration
const APTOS_NETWORK: Network = NetworkToNetworkName[process.env.APTOS_NETWORK ?? Network.DEVNET]
const config = new AptosConfig({network: APTOS_NETWORK})
const client = new Aptos(config)

// You'll need to set your private key here or load from environment
const PRIVATE_KEY_RAW = process.env.PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY || 'your-private-key-here'
const PRIVATE_KEY = PRIVATE_KEY_RAW.startsWith('ed25519-priv-') ? PRIVATE_KEY_RAW.replace('ed25519-priv-', '') : PRIVATE_KEY_RAW
const privateKey = new Ed25519PrivateKey(PRIVATE_KEY)
const account = Account.fromPrivateKey({privateKey})

// Package address (update this with your deployed package address)
const PACKAGE_ADDRESS = '0xb4fbc45cfc95f383d157744e7dd7c67730ef7e8a1d785c5bead8e9017069a603'

// Token types (using custom token)
const FEE_TOKEN_TYPE = `${PACKAGE_ADDRESS}::my_token::SimpleToken`
const ACCESS_TOKEN_TYPE = `${PACKAGE_ADDRESS}::my_token::SimpleToken`

// Configuration values
const SRC_RESCUE_DELAY = 86400 // 24 hours in seconds
const DST_RESCUE_DELAY = 86400 // 24 hours in seconds
const MIN_ACCESS_TOKEN_BALANCE = 1000000 // 1M tokens minimum balance
const LIMIT_ORDER_PROTOCOL_ADDRESS = '0x1' // Replace with actual protocol address

async function initializeModules() {
    console.log('🚀 Starting module initialization...')
    console.log(`Account address: ${account.accountAddress.toString()}`)

    try {
        // Step 1: Initialize token contract
        console.log('\n🪙 Step 1: Initializing token contract...')

        await submitTransaction(
            {
                function: `${PACKAGE_ADDRESS}::my_token::initialize`,
                typeArguments: [],
                functionArguments: ['Fusion Test Token', 'FTT', 8, true]
            },
            'my_token'
        )

        // Step 2: Initialize basic modules (no dependencies)
        console.log('\n📋 Step 2: Initializing basic modules...')

        // Initialize escrow_core
        await submitTransaction(
            {
                function: `${PACKAGE_ADDRESS}::escrow_core::initialize`,
                typeArguments: [],
                functionArguments: []
            },
            'escrow_core'
        )

        // Initialize merkle_validator
        await submitTransaction(
            {
                function: `${PACKAGE_ADDRESS}::merkle_validator::initialize`,
                typeArguments: [],
                functionArguments: []
            },
            'merkle_validator'
        )

        // Step 3: Initialize fee bank modules
        console.log('\n💰 Step 3: Initializing fee bank modules...')

        // Initialize fee bank
        await submitTransaction(
            {
                function: `${PACKAGE_ADDRESS}::fee_bank::initialize_fee_bank`,
                typeArguments: [FEE_TOKEN_TYPE],
                functionArguments: []
            },
            'fee_bank'
        )

        // Initialize access token config
        await submitTransaction(
            {
                function: `${PACKAGE_ADDRESS}::fee_bank::initialize_access_token`,
                typeArguments: [ACCESS_TOKEN_TYPE],
                functionArguments: [MIN_ACCESS_TOKEN_BALANCE]
            },
            'access_token_config'
        )

        // Step 4: Initialize escrow factory
        console.log('\n🏭 Step 4: Initializing escrow factory...')

        const fee_bank_owner = account.accountAddress.toString()
        const access_token_config_addr = account.accountAddress.toString()

        await submitTransaction(
            {
                function: `${PACKAGE_ADDRESS}::escrow_factory::initialize`,
                typeArguments: [FEE_TOKEN_TYPE, ACCESS_TOKEN_TYPE],
                functionArguments: [SRC_RESCUE_DELAY, DST_RESCUE_DELAY, fee_bank_owner, access_token_config_addr]
            },
            'escrow_factory'
        )

        // Step 5: Initialize order integration
        console.log('\n🔄 Step 5: Initializing order integration...')

        const factory_address = account.accountAddress.toString()

        await submitTransaction(
            {
                function: `${PACKAGE_ADDRESS}::order_integration::initialize`,
                typeArguments: [FEE_TOKEN_TYPE, ACCESS_TOKEN_TYPE],
                functionArguments: [LIMIT_ORDER_PROTOCOL_ADDRESS, factory_address]
            },
            'order_integration'
        )

        console.log('\n✅ All modules initialized successfully!')

        // Optional: Initialize escrow factory in escrow_core (if needed)
        console.log('\n🔧 Step 5: Finalizing escrow core setup...')
        try {
            await submitTransaction(
                {
                    function: `${PACKAGE_ADDRESS}::escrow_core::initialize`,
                    typeArguments: [],
                    functionArguments: []
                },
                'escrow_core_finalize'
            )
        } catch (error) {
            console.log('⚠️  Escrow core already initialized or not needed')
        }

        console.log('\n🎉 Initialization complete! Your contracts are ready to use.')
    } catch (error) {
        console.error('❌ Initialization failed:', error)
        process.exit(1)
    }
}

async function submitTransaction(payload: any, step: string) {
    try {
        console.log(`  📤 Submitting: ${step}`)

        const transaction = await client.transaction.build.simple({
            sender: account.accountAddress,
            data: payload
        })

        const senderAuthenticator = client.transaction.sign({
            signer: account,
            transaction
        })

        const transactionRes = await client.transaction.submit.simple({
            transaction,
            senderAuthenticator
        })

        console.log(`  ⏳ Transaction hash: ${transactionRes.hash}`)

        await client.waitForTransaction({transactionHash: transactionRes.hash})
        console.log(`  ✅ ${step} initialized successfully`)

        // Small delay between transactions
        await new Promise((resolve) => setTimeout(resolve, 1000))
    } catch (error: any) {
        if (error.message?.includes('EALREADY_EXISTS') || error.message?.includes('already_exists')) {
            console.log(`  ⚠️  ${step} already initialized`)
        } else {
            console.error(`  ❌ Failed to initialize ${step}:`, error.message)
            throw error
        }
    }
}

// Helper function to check if modules are already initialized
async function checkInitializationStatus() {
    console.log('\n🔍 Checking initialization status...')

    const address = account.accountAddress.toString()

    try {
        // Check account resources
        const resources = await client.getAccountResources({accountAddress: address})

        console.log('\n📊 Current resources:')
        resources.forEach((resource) => {
            if (
                resource.type.includes('EscrowRegistry') ||
                resource.type.includes('MerkleStorage') ||
                resource.type.includes('FeeBank') ||
                resource.type.includes('EscrowFactory') ||
                resource.type.includes('OrderIntegration')
            ) {
                console.log(`  ✅ ${resource.type}`)
            }
        })
    } catch (error) {
        console.log('  ℹ️  No resources found (first time setup)')
    }
}

// Main execution
async function main() {
    console.log('🌟 Fusion+ Aptos Contract Initialization')
    console.log('=====================================')

    // Validate configuration
    if (PRIVATE_KEY === 'your-private-key-here') {
        console.error('❌ Please set your PRIVATE_KEY environment variable or update the script')
        process.exit(1)
    }

    await checkInitializationStatus()
    await initializeModules()
}

// Export for use as module
export {initializeModules, checkInitializationStatus}

// Run if called directly
if (require.main === module) {
    main().catch(console.error)
}
