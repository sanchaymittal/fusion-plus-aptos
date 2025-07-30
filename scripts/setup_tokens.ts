import {Account, Aptos, AptosConfig, Network, NetworkToNetworkName, Ed25519PrivateKey} from '@aptos-labs/ts-sdk'
import * as dotenv from 'dotenv'

dotenv.config()

const APTOS_NETWORK: Network = NetworkToNetworkName[process.env.APTOS_NETWORK ?? Network.DEVNET]
const config = new AptosConfig({network: APTOS_NETWORK})
const client = new Aptos(config)

const PRIVATE_KEY_RAW = process.env.DEPLOYER_PRIVATE_KEY || 'your-private-key-here'
const PRIVATE_KEY = PRIVATE_KEY_RAW.startsWith('ed25519-priv-')
    ? PRIVATE_KEY_RAW.replace('ed25519-priv-', '')
    : PRIVATE_KEY_RAW
const privateKey = new Ed25519PrivateKey(PRIVATE_KEY)
const account = Account.fromPrivateKey({privateKey})
const address = account.accountAddress.toString()
const PACKAGE_ADDRESS = '0xb99c15a2260306d00e120f07df53225df91051e7632ce71b3dda998bdbf1aee7'
const SRC_COIN_TYPE = `${PACKAGE_ADDRESS}::my_token::SimpleToken`

async function setupTokens() {
    console.log('🏗️ Setting up tokens for address:', address)

    try {
        // Step 1: Fund account with APT from faucet
        console.log('💧 Step 1: Funding account with APT from faucet...')
        await client.fundAccount({
            accountAddress: address,
            amount: 100_000_000 // 1 APT = 100M octas
        })
        console.log('✅ Account funded with 1 APT')

        // Step 2: Register for custom token
        console.log('📝 Step 2: Registering for custom token...')
        const registerPayload = {
            function: '0x1::managed_coin::register',
            typeArguments: [SRC_COIN_TYPE],
            functionArguments: []
        }

        const registerTxn = await client.transaction.build.simple({
            sender: account.accountAddress,
            data: registerPayload
        })

        const registerAuth = client.transaction.sign({
            signer: account,
            transaction: registerTxn
        })

        const registerResult = await client.transaction.submit.simple({
            transaction: registerTxn,
            senderAuthenticator: registerAuth
        })

        await client.waitForTransaction({transactionHash: registerResult.hash})
        console.log('✅ Registered for custom token')

        // Step 3: Mint custom tokens
        console.log('🪙 Step 3: Minting custom tokens...')
        const mintPayload = {
            function: `${PACKAGE_ADDRESS}::my_token::mint`,
            typeArguments: [],
            functionArguments: [address, 1_000_000_000_000] // 1T tokens (with 8 decimals = 10M tokens)
        }

        const mintTxn = await client.transaction.build.simple({
            sender: account.accountAddress,
            data: mintPayload
        })

        const mintAuth = client.transaction.sign({
            signer: account,
            transaction: mintTxn
        })

        const mintResult = await client.transaction.submit.simple({
            transaction: mintTxn,
            senderAuthenticator: mintAuth
        })

        await client.waitForTransaction({transactionHash: mintResult.hash})
        console.log('✅ Custom tokens minted')

        // Step 4: Check final balances
        console.log('🔍 Step 4: Checking final balances...')
        const resources = await client.getAccountResources({accountAddress: address})

        // APT balance
        const aptCoinStoreType = '0x1::coin::CoinStore<0x1::aptos_coin::AptosCoin>'
        const aptCoinStore = resources.find((resource) => resource.type === aptCoinStoreType)
        if (aptCoinStore && aptCoinStore.data) {
            const data = aptCoinStore.data as any
            const balance = BigInt(data.coin.value || '0')
            console.log(
                `💰 APT Balance: ${balance.toString()} octas (${(Number(balance) / 100_000_000).toFixed(4)} APT)`
            )
        }

        // Custom token balance
        const tokenCoinStoreType = `0x1::coin::CoinStore<${SRC_COIN_TYPE}>`
        const tokenCoinStore = resources.find((resource) => resource.type === tokenCoinStoreType)
        if (tokenCoinStore && tokenCoinStore.data) {
            const data = tokenCoinStore.data as any
            const balance = BigInt(data.coin.value || '0')
            console.log(
                `🪙 Custom Token Balance: ${balance.toString()} units (${(Number(balance) / 100_000_000).toFixed(4)} tokens)`
            )
        }

        console.log('🎉 Account setup complete! Ready for testing.')
    } catch (error: any) {
        if (error.message?.includes('EALREADY_EXISTS') || error.message?.includes('already_exists')) {
            console.log('⚠️ Resource already exists, continuing...')
        } else {
            console.error('❌ Error setting up tokens:', error.message)
            throw error
        }
    }
}

// Run the setup
setupTokens().catch(console.error)
