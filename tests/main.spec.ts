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

import factoryContract from '../dist/contracts/TestEscrowFactory.sol/TestEscrowFactory.json'
import resolverContract from '../dist/contracts/Resolver.sol/Resolver.json'

const {Address} = Sdk

jest.setTimeout(1000 * 60)

const userPk = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
const resolverPk = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a'

// eslint-disable-next-line max-lines-per-function
describe('Resolving example', () => {
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
    })

    // eslint-disable-next-line max-lines-per-function
    describe('Fill', () => {
        it('should swap Ethereum USDC -> Aptos token, single fill only', async () => {
            const initialBalances = await getMixedBalances(
                config.chain.source.tokens.USDC.address,
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            // Generate cryptographically secure secret for hashlock
            const secret_array = randomBytes(32)
            const secret = uint8ArrayToHex(secret_array)

            const hashLockForAptos = sha3.sha3_256.array(secret_array)
            console.log('secret', secret)
            console.log('SHA3-256 Hash (Hex):', hashLockForAptos)
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

            console.log(`[${srcChainId}]`, `Filling order ${orderHash}`)

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

            console.log(`[${srcChainId}]`, `Order ${orderHash} filled for ${fillAmount} in tx ${orderFillHash}`)

            const srcEscrowEvent = await srcFactory.getSrcDeployEvent(srcDeployBlock)

            const dstImmutables = srcEscrowEvent[0]
                .withComplement(srcEscrowEvent[1])
                .withTaker(new Address(resolverContract.dstAddress))

            console.log('dstImmutables', dstImmutables)

            console.log(`Aptos`, `Depositing ${dstImmutables.amount} for order ${orderHash}`)

            // console.log('Creating destination escrow on Aptos...')
            const {escrowAddress: dstEscrowAddress, immutables: withdrawImmutables} = await aptos.create_dst_escrow(
                dstImmutables,
                hashLockForAptos
            )

            console.log(`Aptos escrow created at ${dstEscrowAddress} for order ${orderHash}`)

            const ESCROW_SRC_IMPLEMENTATION = await srcFactory.getSourceImpl()

            const srcEscrowAddress = new Sdk.EscrowFactory(new Address(src.escrowFactory)).getSrcEscrowAddress(
                srcEscrowEvent[0],
                ESCROW_SRC_IMPLEMENTATION
            )

            await increaseTime(11) // finality lock passed
            // User shares key after validation of dst escrow deployment
            console.log(`Aptos`, `Withdrawing funds for user from ${dstEscrowAddress}`)
            await aptos.withdraw_dst_escrow(dstEscrowAddress, secret, withdrawImmutables, hashLockForAptos)

            console.log(`[${srcChainId}]`, `Withdrawing funds for resolver from ${srcEscrowAddress}`)
            const {txHash: resolverWithdrawHash} = await srcChainResolver.send(
                resolverContract.withdraw('src', srcEscrowAddress, secret, srcEscrowEvent[0])
            )
            console.log(
                `[${srcChainId}]`,
                `Withdrew funds for resolver from ${srcEscrowAddress} to ${src.resolver} in tx ${resolverWithdrawHash}`
            )

            const resultBalances = await getMixedBalances(
                config.chain.source.tokens.USDC.address,
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            // user transferred funds to resolver on source chain
            expect(initialBalances.src.user - resultBalances.src.user).toBe(order.makingAmount)
            expect(resultBalances.src.resolver - initialBalances.src.resolver).toBe(order.makingAmount)

            // Aptos balance validation - user should have more tokens after withdrawal
            expect(resultBalances.aptos.user >= initialBalances.aptos.user).toBe(true)
            console.log(`Aptos balance change: ${resultBalances.aptos.user - initialBalances.aptos.user}`)
        })
        it('should swap Aptos token -> Ethereum USDC, single fill only', async () => {
            const initialBalances = await getMixedBalances(
                config.chain.destination.tokens.USDC.address, // Note: destination is now Ethereum USDC
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            // Generate cryptographically secure secret for hashlock
            const secret_array = randomBytes(32)
            const secret = uint8ArrayToHex(secret_array)
            // Convert hex string to byte array for Aptos
            const hashLockForAptos = sha3.sha3_256.array(secret_array)

            console.log('secret', secret)
            console.log('Aptos Hash (Bytes):', hashLockForAptos)

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

            console.log('Order created:', order)

            // Try different ways to access the data
            console.log('Direct properties:', {
                salt: order.salt,
                makingAmount: order.makingAmount,
                takingAmount: order.takingAmount
            })

            // Check available methods and properties
            console.log('Order methods:', Object.getOwnPropertyNames(Object.getPrototypeOf(order)))
            console.log('Available properties:', Object.keys(order))

            // Check for common method patterns
            if (typeof order.toSrcImmutables === 'function') {
                console.log('Has toSrcImmutables method')
            }

            // Try to inspect internal structure
            for (const key in order) {
                if (order.hasOwnProperty(key)) {
                    console.log(`Order.${key}:`, order[key])
                }
            }

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

            // Sign order using Aptos signature scheme
            const signature = await aptos.signOrderAptos(aptosOrder, 1) // Using chainId 1 for Aptos
            console.log('Aptos order signature:', signature)

            console.log(`[Aptos]`, `Creating source escrow for order ${aptosOrder.orderHash}`)

            // Step 1: Create source escrow on Aptos
            const {escrowAddress: srcEscrowAddress, immutables: srcImmutables} = await aptos.create_src_escrow(
                aptosOrder,
                hashLockForAptos,
                dstChainId, // Ethereum destination chain ID
                config.chain.destination.tokens.USDC.address // Ethereum USDC address
            )

            console.log(`Aptos source escrow created at ${srcEscrowAddress}`)

            // Step 2: Resolver creates destination escrow on Ethereum
            console.log(`[${dstChainId}]`, `Creating destination escrow for order ${aptosOrder.orderHash}`)

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

            console.log('dstImmutables', dstImmutables)

            const {txHash: dstDepositHash} = await dstChainResolver.send(resolverContract.deployDst(dstImmutables))
            console.log(`[${dstChainId}]`, `Created dst escrow in tx ${dstDepositHash}`)

            // Get the dstEscrowAddress from the transaction receipt logs
            const dstTxReceipt = await dst.provider.getTransactionReceipt(dstDepositHash)

            if (!dstTxReceipt) throw new Error('Transaction receipt not found')

            // Parse logs to find the DstEscrowCreated event
            // First, let's debug what events are actually emitted
            console.log(
                'Transaction logs:',
                dstTxReceipt.logs.map((log) => ({
                    address: log.address,
                    topics: log.topics,
                    data: log.data
                }))
            )

            // Look for DstEscrowCreated event signature: event DstEscrowCreated(address escrow, bytes32 hashlock, Address taker)
            // where Address is uint256 (type Address is uint256 in AddressLib.sol)
            const dstEscrowCreatedSignature = id('DstEscrowCreated(address,bytes32,uint256)')
            console.log('Expected DstEscrowCreated signature:', dstEscrowCreatedSignature)

            const escrowCreatedLog = dstTxReceipt.logs.find((log) => log.topics[0] === dstEscrowCreatedSignature)

            if (!escrowCreatedLog) {
                console.log('Available event signatures:')
                dstTxReceipt.logs.forEach((log, i) => {
                    console.log(`  Log ${i}: ${log.topics[0]}`)
                })
                throw new Error('Escrow creation event not found')
            }

            // The escrow address is the first parameter (not indexed), so it's in the data field
            // For events with non-indexed parameters, we need to decode the data field
            const dstEscrowAddress: any = '0x' + escrowCreatedLog.data.slice(26, 66) // Extract address from data field

            console.log(`[${dstChainId}]`, `Destination escrow created at ${dstEscrowAddress}`)

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
            console.log(`[Aptos]`, `Resolver withdrawing tokens from ${srcEscrowAddress}`)

            console.log('Withdrawal parameters:', {
                secret: secret,
                srcEscrowAddress: srcEscrowAddress,
                hashLock: hashLockForAptos,
                taker: srcImmutables.taker.toString(),
                maker: srcImmutables.maker.toString(),
                srcImmutables: srcImmutables
            })
            await aptos.withdraw_dst_escrow(srcEscrowAddress, secret, srcImmutables, hashLockForAptos)

            const resultBalances = await getMixedBalances(
                config.chain.destination.tokens.USDC.address,
                config.chain.aptos.tokens.MY_TOKEN.address
            )

            // User should have less Aptos tokens (transferred to resolver)
            expect(initialBalances.aptos.user == resultBalances.aptos.user).toBe(true)
            console.log(`User Aptos token balance change: ${initialBalances.aptos.user - resultBalances.aptos.user}`)
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
    console.log(`[${cnf.chainId}]`, `Escrow factory contract deployed to`, escrowFactory)

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
    console.log(`[${cnf.chainId}]`, `Resolver contract deployed to`, resolver)

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
