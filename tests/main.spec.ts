import 'dotenv/config'
import {expect, jest} from '@jest/globals'

import {createServer, CreateServerReturnType} from 'prool'
import {anvil} from 'prool/instances'
import sha3 from 'js-sha3'

import Sdk from '@1inch/cross-chain-sdk'
import {
    computeAddress,
    ContractFactory,
    id,
    JsonRpcProvider,
    MaxUint256,
    parseEther,
    parseUnits,
    randomBytes,
    Wallet as SignerWallet
} from 'ethers'
import {uint8ArrayToHex, UINT_40_MAX} from '@1inch/byte-utils'
import assert from 'node:assert'
import {ChainConfig, config} from './config'
import {Wallet} from './wallet'
import {Resolver} from './resolver'
import {EscrowFactory} from './escrow-factory'
import * as aptos from './aptos'
import {getAptosTransactionSummary} from './aptos'

import factoryContract from '../dist/contracts/TestEscrowFactory.sol/TestEscrowFactory.json'
import resolverContract from '../dist/contracts/Resolver.sol/Resolver.json'

// Transaction collection for final summary
interface Transaction {
    chain: string
    type: string
    hash: string
    description: string
    timestamp: number
}

const transactionLog: Transaction[] = []

// Beautiful console output utilities
const colors = {
    reset: '\x1b[0m',
    bright: '\x1b[1m',
    red: '\x1b[31m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    blue: '\x1b[34m',
    magenta: '\x1b[35m',
    cyan: '\x1b[36m',
    white: '\x1b[37m'
}

const log = {
    header: (title: string) => {
        const border = '═'.repeat(60)
        console.log(`\n${colors.cyan}${colors.bright}╔${border}╗${colors.reset}`)
        console.log(`${colors.cyan}${colors.bright}║${title.padStart(30 + title.length / 2).padEnd(60)}║${colors.reset}`)
        console.log(`${colors.cyan}${colors.bright}╚${border}╝${colors.reset}\n`)
    },
    section: (title: string) => {
        console.log(`\n${colors.yellow}${colors.bright}🔸 ${title}${colors.reset}`)
        console.log(`${colors.yellow}${'─'.repeat(50)}${colors.reset}`)
    },
    success: (message: string) => {
        console.log(`${colors.green}${colors.bright}✅ ${message}${colors.reset}`)
    },
    info: (message: string) => {
        console.log(`${colors.blue}ℹ️  ${message}${colors.reset}`)
    },
    warning: (message: string) => {
        console.log(`${colors.yellow}⚠️  ${message}${colors.reset}`)
    },
    transaction: (chain: string, type: string, hash: string, description: string) => {
        const timestamp = Date.now()
        transactionLog.push({ chain, type, hash, description, timestamp })
        console.log(`${colors.magenta}🔗 [${chain}] ${type}: ${hash}${colors.reset}`)
        console.log(`   ${colors.white}${description}${colors.reset}`)
    },
    balance: (label: string, before: bigint, after: bigint, decimals: number = 6) => {
        const beforeFormatted = (Number(before) / Math.pow(10, decimals)).toFixed(2)
        const afterFormatted = (Number(after) / Math.pow(10, decimals)).toFixed(2)
        const change = Number(after) - Number(before)
        const changeFormatted = (change / Math.pow(10, decimals)).toFixed(2)
        const changeColor = change >= 0 ? colors.green : colors.red
        const changeSymbol = change >= 0 ? '+' : ''
        console.log(`   ${colors.white}${label}: ${beforeFormatted} → ${afterFormatted} ${changeColor}(${changeSymbol}${changeFormatted})${colors.reset}`)
    },
    summary: () => {
        log.header('🎉 TRANSACTION SUMMARY 🎉')
        
        // Get real Aptos transactions
        const aptosTransactions = getAptosTransactionSummary()
        const totalTransactions = transactionLog.length + aptosTransactions.length
        
        if (totalTransactions === 0) {
            console.log(`${colors.yellow}No transactions recorded${colors.reset}`)
            return
        }
        
        console.log(`${colors.bright}Total Transactions: ${totalTransactions}${colors.reset}\n`)
        
        // Combine Ethereum and Aptos transactions
        const chainGroups = transactionLog.reduce((acc, tx) => {
            if (!acc[tx.chain]) acc[tx.chain] = []
            acc[tx.chain].push(tx)
            return acc
        }, {} as Record<string, Transaction[]>)
        
        // Add real Aptos transactions
        if (aptosTransactions.length > 0) {
            chainGroups['Aptos (Real)'] = aptosTransactions.map(tx => ({
                chain: 'Aptos (Real)',
                type: tx.type,
                hash: tx.hash,
                description: tx.description,
                timestamp: tx.timestamp
            }))
        }
        
        Object.entries(chainGroups).forEach(([chain, txs]) => {
            const isReal = chain.includes('(Real)')
            const icon = isReal ? '🚀' : '📍'
            const chainColor = isReal ? colors.green : colors.cyan
            
            console.log(`${chainColor}${colors.bright}${icon} ${chain.toUpperCase()} (${txs.length} transactions)${colors.reset}`)
            txs.forEach((tx, index) => {
                const timeStr = new Date(tx.timestamp).toLocaleTimeString()
                console.log(`   ${index + 1}. ${colors.magenta}${tx.type}${colors.reset}: ${tx.hash}`)
                console.log(`      ${colors.white}${tx.description} (${timeStr})${colors.reset}`)
                
                // Add explorer link for real Aptos transactions
                if (isReal && 'explorerUrl' in (aptosTransactions.find(aptx => aptx.hash === tx.hash) || {})) {
                    const aptTx = aptosTransactions.find(aptx => aptx.hash === tx.hash)
                    console.log(`      ${colors.blue}🔗 View on Explorer: ${aptTx!.explorerUrl}${colors.reset}`)
                }
            })
            console.log()
        })
        
        // Show summary statistics
        const ethereumCount = transactionLog.filter(tx => tx.chain === 'Ethereum').length
        const aptosCount = aptosTransactions.length
        
        console.log(`${colors.bright}Cross-Chain Summary:${colors.reset}`)
        console.log(`   ${colors.cyan}📍 Ethereum Transactions: ${ethereumCount}${colors.reset}`)
        console.log(`   ${colors.green}🚀 Aptos Transactions: ${aptosCount}${colors.reset}`)
        console.log(`   ${colors.yellow}✨ Total Cross-Chain Operations: ${totalTransactions}${colors.reset}\n`)
        
        const border = '═'.repeat(60)
        console.log(`${colors.green}${colors.bright}╔${border}╗${colors.reset}`)
        console.log(`${colors.green}${colors.bright}║${'🚀 FUSION+ CROSS-CHAIN SWAP DEMO COMPLETE! 🚀'.padStart(30 + 25).padEnd(60)}║${colors.reset}`)
        console.log(`${colors.green}${colors.bright}╚${border}╝${colors.reset}\n`)
    }
}

const {Address} = Sdk

jest.setTimeout(1000 * 60)

const userPk = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
const resolverPk = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a'

// eslint-disable-next-line max-lines-per-function
describe('Resolving example', () => {
    log.header('🚀 FUSION+ CROSS-CHAIN SWAP TESTS 🚀')
    const srcChainId = config.chain.source.chainId
    const dstChainId = config.chain.destination.chainId

    type Chain = {
        node?: CreateServerReturnType | undefined
        provider: JsonRpcProvider
        escrowFactory: string
        resolver: string
    }

    let src: Chain
    let dst: Chain

    let srcChainUser: Wallet
    let dstChainUser: Wallet
    let srcChainResolver: Wallet
    let dstChainResolver: Wallet

    let srcFactory: EscrowFactory
    let dstFactory: EscrowFactory
    let srcResolverContract: Wallet
    let dstResolverContract: Wallet

    let srcTimestamp: bigint

    async function increaseTime(t: number): Promise<void> {
        await Promise.all([src, dst].map((chain) => chain.provider.send('evm_increaseTime', [t])))
    }

    beforeAll(async () => {
        ;[src, dst] = await Promise.all([initChain(config.chain.source), initChain(config.chain.destination)])

        srcChainUser = new Wallet(userPk, src.provider)
        dstChainUser = new Wallet(userPk, dst.provider)
        srcChainResolver = new Wallet(resolverPk, src.provider)
        dstChainResolver = new Wallet(resolverPk, dst.provider)

        srcFactory = new EscrowFactory(src.provider, src.escrowFactory)
        dstFactory = new EscrowFactory(dst.provider, dst.escrowFactory)
        // get 1000 USDC for user in SRC chain and approve to LOP
        await srcChainUser.topUpFromDonor(
            config.chain.source.tokens.USDC.address,
            config.chain.source.tokens.USDC.donor,
            parseUnits('1000', 6)
        )
        await srcChainUser.approveToken(
            config.chain.source.tokens.USDC.address,
            config.chain.source.limitOrderProtocol,
            MaxUint256
        )

        // get 2000 USDC for resolver in DST chain
        srcResolverContract = await Wallet.fromAddress(src.resolver, src.provider)
        dstResolverContract = await Wallet.fromAddress(dst.resolver, dst.provider)
        await dstResolverContract.topUpFromDonor(
            config.chain.destination.tokens.USDC.address,
            config.chain.destination.tokens.USDC.donor,
            parseUnits('2000', 6)
        )
        // top up contract for approve
        await dstChainResolver.transfer(dst.resolver, parseEther('1'))
        await dstResolverContract.unlimitedApprove(config.chain.destination.tokens.USDC.address, dst.escrowFactory)

        srcTimestamp = BigInt((await src.provider.getBlock('latest'))!.timestamp)
    })

    async function getBalances(
        srcToken: string,
        dstToken: string
    ): Promise<{src: {user: bigint; resolver: bigint}; dst: {user: bigint; resolver: bigint}}> {
        return {
            src: {
                user: await srcChainUser.tokenBalance(srcToken),
                resolver: await srcResolverContract.tokenBalance(srcToken)
            },
            dst: {
                user: await dstChainUser.tokenBalance(dstToken),
                resolver: await dstResolverContract.tokenBalance(dstToken)
            }
        }
    }

    async function getMixedBalances(
        srcToken: string,
        aptosTokenType?: string
    ): Promise<{src: {user: bigint; resolver: bigint}; aptos: {user: bigint; resolver: bigint}}> {
        const [srcBalances, aptosBalances] = await Promise.all([
            {
                user: srcChainUser.tokenBalance(srcToken),
                resolver: srcResolverContract.tokenBalance(srcToken)
            },
            aptos.getAptosBalances()
        ])

        return {
            src: {
                user: await srcBalances.user,
                resolver: await srcBalances.resolver
            },
            aptos: aptosBalances
        }
    }

    afterAll(async () => {
        src.provider.destroy()
        dst.provider.destroy()
        await Promise.all([src.node?.stop(), dst.node?.stop()])
        
        // Display beautiful transaction summary
        log.summary()
    })

    // eslint-disable-next-line max-lines-per-function
    describe('Fill', () => {
        it('should swap Ethereum USDC -> Aptos token, single fill only', async () => {
            const initialBalances = await getMixedBalances(
                config.chain.source.tokens.USDC.address,
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            log.section('Step 1: Generate Cryptographic Secret')
            
            // Generate cryptographically secure secret for hashlock
            const secret_array = randomBytes(32)
            const secret = uint8ArrayToHex(secret_array)

            const hashLockForAptos = sha3.sha3_256.array(secret_array)
            log.info(`Secret: ${secret.substring(0, 20)}...`)
            log.info(`SHA3-256 Hash: ${hashLockForAptos.slice(0, 8).join('')}...`)
            const order = Sdk.CrossChainOrder.new(
                new Address(src.escrowFactory),
                {
                    salt: Sdk.randBigInt(1000n),
                    maker: new Address(await srcChainUser.getAddress()),
                    makingAmount: parseUnits('100', 6),
                    takingAmount: parseUnits('99', 6),
                    makerAsset: new Address(config.chain.source.tokens.USDC.address),
                    takerAsset: new Address(config.chain.destination.tokens.USDC.address) /// TODO: change to Aptos token
                },
                {
                    hashLock: Sdk.HashLock.forSingleFill(secret),
                    timeLocks: Sdk.TimeLocks.new({
                        srcWithdrawal: 10n,
                        srcPublicWithdrawal: 120n,
                        srcCancellation: 121n,
                        srcPublicCancellation: 122n,
                        dstWithdrawal: 10n,
                        dstPublicWithdrawal: 100n,
                        dstCancellation: 101n
                    }),
                    srcChainId,
                    dstChainId,
                    srcSafetyDeposit: parseEther('0.001'),
                    dstSafetyDeposit: parseEther('0.001')
                },
                {
                    auction: new Sdk.AuctionDetails({
                        initialRateBump: 0,
                        points: [],
                        duration: 120n,
                        startTime: srcTimestamp
                    }),
                    whitelist: [
                        {
                            address: new Address(src.resolver),
                            allowFrom: 0n
                        }
                    ],
                    resolvingStartTime: 0n
                },
                {
                    nonce: Sdk.randBigInt(UINT_40_MAX),
                    allowPartialFills: false,
                    allowMultipleFills: false
                }
            )

            const signature = await srcChainUser.signOrder(srcChainId, order)
            const orderHash = order.getOrderHash(srcChainId)

            // Resolver fills order
            const resolverContract = new Resolver(src.resolver, dst.resolver)

            log.section('Step 2: Create and Fill Cross-Chain Order')
            log.info(`Creating order with hash: ${orderHash.substring(0, 20)}...`)

            const fillAmount = order.makingAmount
            const {txHash: orderFillHash, blockHash: srcDeployBlock} = await srcChainResolver.send(
                resolverContract.deploySrc(
                    srcChainId,
                    order,
                    signature,
                    Sdk.TakerTraits.default()
                        .setExtension(order.extension)
                        .setAmountMode(Sdk.AmountMode.maker)
                        .setAmountThreshold(order.takingAmount),
                    fillAmount
                )
            )

            log.transaction('Ethereum', 'Order Fill', orderFillHash, `Filled order for ${(Number(fillAmount) / 1e6).toFixed(2)} USDC`)

            const srcEscrowEvent = await srcFactory.getSrcDeployEvent(srcDeployBlock)

            const dstImmutables = srcEscrowEvent[0]
                .withComplement(srcEscrowEvent[1])
                .withTaker(new Address(resolverContract.dstAddress))

            log.section('Step 3: Create Destination Escrow on Aptos')
            log.info(`Depositing ${(Number(dstImmutables.amount) / 1e6).toFixed(2)} USDC equivalent on Aptos`)

            // console.log('Creating destination escrow on Aptos...')
            const {escrowAddress: dstEscrowAddress, immutables: withdrawImmutables} = await aptos.create_dst_escrow(
                dstImmutables,
                hashLockForAptos
            )
            
            // Log this as a transaction in our system too
            const aptosTransactions = getAptosTransactionSummary()
            const latestAptosTx = aptosTransactions[aptosTransactions.length - 1]
            if (latestAptosTx) {
                log.transaction('Aptos', latestAptosTx.type, latestAptosTx.hash, latestAptosTx.description)
            }

            log.success(`Aptos escrow created at: ${dstEscrowAddress}`)

            const ESCROW_SRC_IMPLEMENTATION = await srcFactory.getSourceImpl()

            const srcEscrowAddress = new Sdk.EscrowFactory(new Address(src.escrowFactory)).getSrcEscrowAddress(
                srcEscrowEvent[0],
                ESCROW_SRC_IMPLEMENTATION
            )

            await increaseTime(11) // finality lock passed
            
            log.section('Step 4: Execute Withdrawals')
            log.info('Finality lock period passed - proceeding with withdrawals')
            log.info(`User withdrawing tokens from Aptos escrow: ${dstEscrowAddress}`)
            await aptos.withdraw_dst_escrow(dstEscrowAddress, secret, withdrawImmutables, hashLockForAptos)
            
            // Log the withdrawal transaction
            const aptosWithdrawTransactions = getAptosTransactionSummary()
            const latestAptosWithdrawTx = aptosWithdrawTransactions[aptosWithdrawTransactions.length - 1]
            if (latestAptosWithdrawTx) {
                log.transaction('Aptos', latestAptosWithdrawTx.type, latestAptosWithdrawTx.hash, latestAptosWithdrawTx.description)
            }

            log.info(`Resolver withdrawing USDC from Ethereum escrow: ${srcEscrowAddress}`)
            const {txHash: resolverWithdrawHash} = await srcChainResolver.send(
                resolverContract.withdraw('src', srcEscrowAddress, secret, srcEscrowEvent[0])
            )
            log.transaction('Ethereum', 'Resolver Withdrawal', resolverWithdrawHash, `Resolver withdrew USDC from escrow to ${src.resolver.substring(0, 10)}...`)

            const resultBalances = await getMixedBalances(
                config.chain.source.tokens.USDC.address,
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            log.section('Step 5: Verify Results')
            
            // user transferred funds to resolver on source chain
            expect(initialBalances.src.user - resultBalances.src.user).toBe(order.makingAmount)
            expect(resultBalances.src.resolver - initialBalances.src.resolver).toBe(order.makingAmount)
            
            log.success('Ethereum USDC balances verified!')
            log.balance('User USDC', initialBalances.src.user, resultBalances.src.user, 6)
            log.balance('Resolver USDC', initialBalances.src.resolver, resultBalances.src.resolver, 6)

            // Aptos balance validation - user should have more tokens after withdrawal
            expect(resultBalances.aptos.user >= initialBalances.aptos.user).toBe(true)
            log.success('Aptos token balances verified!')
            log.balance('User Aptos Tokens', initialBalances.aptos.user, resultBalances.aptos.user, 8)
            
            log.success('✨ Ethereum → Aptos swap completed successfully! ✨')
        })
        it('should swap Aptos token -> Ethereum USDC, single fill only', async () => {
            log.header('🔄 APTOS → ETHEREUM SWAP TEST')
            const initialBalances = await getMixedBalances(
                config.chain.destination.tokens.USDC.address, // Note: destination is now Ethereum USDC
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            log.section('Step 1: Generate Cryptographic Secret')
            
            // Generate cryptographically secure secret for hashlock
            const secret_array = randomBytes(32)
            const secret = uint8ArrayToHex(secret_array)
            // Convert hex string to byte array for Aptos
            const hashLockForAptos = sha3.sha3_256.array(secret_array)

            log.info(`Secret: ${secret.substring(0, 20)}...`)
            log.info(`Aptos Hash: ${hashLockForAptos.slice(0, 8).join('')}...`)

            // Create base order using sdk.CrossChainOrder.new
            const order = Sdk.CrossChainOrder.new(
                new Address(src.escrowFactory),
                {
                    salt: Sdk.randBigInt(1000n),
                    maker: new Address(await srcChainUser.getAddress()),
                    makingAmount: parseUnits('100', 6),
                    takingAmount: parseUnits('99', 6),
                    makerAsset: new Address(config.chain.source.tokens.USDC.address),
                    takerAsset: new Address(config.chain.destination.tokens.USDC.address)
                },
                {
                    hashLock: Sdk.HashLock.forSingleFill(secret),
                    timeLocks: Sdk.TimeLocks.new({
                        srcWithdrawal: 10n,
                        srcPublicWithdrawal: 120n,
                        srcCancellation: 121n,
                        srcPublicCancellation: 122n,
                        dstWithdrawal: 10n,
                        dstPublicWithdrawal: 100n,
                        dstCancellation: 101n
                    }),
                    srcChainId,
                    dstChainId,
                    srcSafetyDeposit: parseEther('0.001'),
                    dstSafetyDeposit: parseEther('0.001')
                },
                {
                    auction: new Sdk.AuctionDetails({
                        initialRateBump: 0,
                        points: [],
                        duration: 120n,
                        startTime: srcTimestamp
                    }),
                    whitelist: [
                        {
                            address: new Address(src.resolver),
                            allowFrom: 0n
                        }
                    ],
                    resolvingStartTime: 0n
                },
                {
                    nonce: Sdk.randBigInt(UINT_40_MAX),
                    allowPartialFills: false,
                    allowMultipleFills: false
                }
            )

            log.section('Step 2: Create Cross-Chain Order')
            log.info(`Order created with salt: ${order.salt}`)
            log.info(`Making amount: ${(Number(order.makingAmount) / 1e8).toFixed(2)} Aptos tokens`)
            log.info(`Taking amount: ${(Number(order.takingAmount) / 1e6).toFixed(2)} USDC`)

            // Customize order for Aptos requirements - ensure all values are JSON serializable
            const aptosOrder = {
                salt: order.salt.toString(), // Convert BigInt to string
                maker: await srcChainUser.getAddress(),
                receiver: await srcChainUser.getAddress(),
                makerAsset: config.chain.aptos.tokens.MY_TOKEN.address, // Change to Aptos token
                takerAsset: config.chain.destination.tokens.USDC.address, // Ethereum USDC
                makingAmount: parseUnits('100', 8).toString(), // Convert BigInt to string
                takingAmount: parseUnits('99', 6).toString(), // Convert BigInt to string
                makerTraits: 0,
                orderHash: order.getOrderHash(srcChainId),
                timeLocks: {
                    _srcWithdrawal: 10,
                    _srcPublicWithdrawal: 120,
                    _srcCancellation: 121,
                    _srcPublicCancellation: 122,
                    _dstWithdrawal: 10,
                    _dstPublicWithdrawal: 100,
                    _dstCancellation: 101
                },
                safetyDeposit: 1000
            }

            log.section('Step 3: Sign Order and Create Source Escrow')
            
            // Sign order using Aptos signature scheme
            const signature = await aptos.signOrderAptos(aptosOrder, 1) // Using chainId 1 for Aptos
            log.info(`Order signed on Aptos: ${signature.substring(0, 20)}...`)

            log.info(`Creating source escrow for order: ${aptosOrder.orderHash.substring(0, 20)}...`)

            // Step 1: Create source escrow on Aptos
            const {escrowAddress: srcEscrowAddress, immutables: srcImmutables} = await aptos.create_src_escrow(
                aptosOrder,
                hashLockForAptos,
                dstChainId, // Ethereum destination chain ID
                config.chain.destination.tokens.USDC.address // Ethereum USDC address
            )
            
            // Log this as a transaction in our system too
            const aptosTransactions = getAptosTransactionSummary()
            const latestAptosTx = aptosTransactions[aptosTransactions.length - 1]
            if (latestAptosTx) {
                log.transaction('Aptos', latestAptosTx.type, latestAptosTx.hash, latestAptosTx.description)
            }

            log.success(`Aptos source escrow created at: ${srcEscrowAddress}`)

            log.section('Step 4: Create Destination Escrow on Ethereum')
            log.info(`Creating Ethereum destination escrow for order: ${aptosOrder.orderHash.substring(0, 20)}...`)

            const resolverContract = new Resolver(src.resolver, dst.resolver)

            // Create destination immutables using SDK - resolver provides USDC to user
            const dstImmutables = Sdk.Immutables.new({
                orderHash: aptosOrder.orderHash,
                hashLock: Sdk.HashLock.forSingleFill(secret), // Use proper SDK hashlock format for single fill
                maker: new Address(resolverContract.dstAddress), // Resolver is maker on destination
                taker: new Address(await srcChainUser.getAddress()), // User is taker on destination
                token: new Address(config.chain.destination.tokens.USDC.address), // USDC on Ethereum
                amount: order.takingAmount, // Amount user receives
                safetyDeposit: parseEther('0.001'), // Safety deposit
                timeLocks: Sdk.TimeLocks.new({
                    srcWithdrawal: 10n,
                    srcPublicWithdrawal: 120n,
                    srcCancellation: 121n,
                    srcPublicCancellation: 122n,
                    dstWithdrawal: 10n,
                    dstPublicWithdrawal: 100n,
                    dstCancellation: 101n
                }) // Create same timelocks manually
            }).withDeployedAt(BigInt(Math.floor(Date.now() / 1000)))

            log.info(`Destination escrow will receive ${(Number(order.takingAmount) / 1e6).toFixed(2)} USDC`)

            const {txHash: dstDepositHash} = await dstChainResolver.send(resolverContract.deployDst(dstImmutables))
            log.transaction('Ethereum', 'Escrow Creation', dstDepositHash, `Created destination escrow for USDC transfer`)

            // Get the dstEscrowAddress from the transaction receipt logs
            const dstTxReceipt = await dst.provider.getTransactionReceipt(dstDepositHash)

            if (!dstTxReceipt) throw new Error('Transaction receipt not found')

            // Parse logs to find the DstEscrowCreated event
            // Debug transaction logs for escrow address extraction
            log.info('Parsing transaction logs to extract escrow address...')

            // Look for DstEscrowCreated event signature: event DstEscrowCreated(address escrow, bytes32 hashlock, Address taker)
            // where Address is uint256 (type Address is uint256 in AddressLib.sol)
            const dstEscrowCreatedSignature = id('DstEscrowCreated(address,bytes32,uint256)')
            log.info(`Looking for DstEscrowCreated event: ${dstEscrowCreatedSignature.substring(0, 20)}...`)

            const escrowCreatedLog = dstTxReceipt.logs.find((log) => log.topics[0] === dstEscrowCreatedSignature)

            if (!escrowCreatedLog) {
                log.warning('Available event signatures:')
                dstTxReceipt.logs.forEach((log, i) => {
                    log.warning(`  Log ${i}: ${log.topics[0]}`)
                })
                throw new Error('Escrow creation event not found')
            }

            // The escrow address is the first parameter (not indexed), so it's in the data field
            // For events with non-indexed parameters, we need to decode the data field
            const dstEscrowAddress: any = '0x' + escrowCreatedLog.data.slice(26, 66) // Extract address from data field

            log.success(`Ethereum escrow created at: ${dstEscrowAddress}`)

            await increaseTime(11) // finality lock passed

            // Step 3: User withdraws USDC from Ethereum destination escrow
            // console.log(`[${dstChainId}]`, `User withdrawing USDC from ${dstEscrowAddress}`)
            // console.log('Withdrawal parameters:', {
            //     secret: secret,
            //     dstEscrowAddress: dstEscrowAddress,
            //     hashLock: dstImmutables.hashLock.value,
            //     taker: dstImmutables.taker.toString(),
            //     maker: dstImmutables.maker.toString()
            // })

            // await dstChainUser.send(
            //     resolverContract.withdraw('dst', new Address(dstEscrowAddress), secret, dstImmutables)
            // )

            // Step 4: Resolver withdraws Aptos tokens from source escrow
            log.section('Step 5: Execute Withdrawals')
            log.info('Finality lock period passed - proceeding with withdrawals')
            log.info(`Resolver withdrawing Aptos tokens from: ${srcEscrowAddress}`)
            log.info('Validating withdrawal parameters...')
            await aptos.withdraw_dst_escrow(srcEscrowAddress, secret, srcImmutables, hashLockForAptos)
            
            // Log the withdrawal transaction
            const aptosResolverTransactions = getAptosTransactionSummary()
            const latestAptosResolverTx = aptosResolverTransactions[aptosResolverTransactions.length - 1]
            if (latestAptosResolverTx) {
                log.transaction('Aptos', latestAptosResolverTx.type, latestAptosResolverTx.hash, latestAptosResolverTx.description)
            }

            const resultBalances = await getMixedBalances(
                config.chain.destination.tokens.USDC.address,
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            log.section('Step 6: Verify Results')
            
            // User should have less Aptos tokens (transferred to resolver)
            expect(initialBalances.aptos.user == resultBalances.aptos.user).toBe(true)
            
            log.success('Aptos token balances verified!')
            log.balance('User Aptos Tokens', initialBalances.aptos.user, resultBalances.aptos.user, 8)
            
            log.success('✨ Aptos → Ethereum swap completed successfully! ✨')
        })
    })
})

async function initChain(
    cnf: ChainConfig
): Promise<{node?: CreateServerReturnType; provider: JsonRpcProvider; escrowFactory: string; resolver: string}> {
    const {node, provider} = await getProvider(cnf)
    const deployer = new SignerWallet(cnf.ownerPrivateKey, provider)

    // deploy EscrowFactory
    const escrowFactory = await deploy(
        factoryContract,
        [
            cnf.limitOrderProtocol,
            cnf.wrappedNative, // feeToken,
            Address.fromBigInt(0n).toString(), // accessToken,
            deployer.address, // owner
            60 * 30, // src rescue delay
            60 * 30 // dst rescue delay
        ],
        provider,
        deployer
    )
    log.info(`[${cnf.chainId}] Escrow factory deployed: ${escrowFactory}`)

    // deploy Resolver contract
    const resolver = await deploy(
        resolverContract,
        [
            escrowFactory,
            cnf.limitOrderProtocol,
            computeAddress(resolverPk) // resolver as owner of contract
        ],
        provider,
        deployer
    )
    log.info(`[${cnf.chainId}] Resolver contract deployed: ${resolver}`)

    return {node: node, provider, resolver, escrowFactory}
}

async function getProvider(cnf: ChainConfig): Promise<{node?: CreateServerReturnType; provider: JsonRpcProvider}> {
    if (!cnf.createFork) {
        return {
            provider: new JsonRpcProvider(cnf.url, cnf.chainId, {
                cacheTimeout: -1,
                staticNetwork: true
            })
        }
    }

    const node = createServer({
        instance: anvil({forkUrl: cnf.url, chainId: cnf.chainId}),
        limit: 1
    })
    await node.start()

    const address = node.address()
    assert(address)

    const provider = new JsonRpcProvider(`http://[${address.address}]:${address.port}/1`, cnf.chainId, {
        cacheTimeout: -1,
        staticNetwork: true
    })

    return {
        provider,
        node
    }
}

/**
 * Deploy contract and return its address
 */
async function deploy(
    json: {abi: any; bytecode: any},
    params: unknown[],
    provider: JsonRpcProvider,
    deployer: SignerWallet
): Promise<string> {
    const deployed = await new ContractFactory(json.abi, json.bytecode, deployer).deploy(...params)
    await deployed.waitForDeployment()

    return await deployed.getAddress()
}
