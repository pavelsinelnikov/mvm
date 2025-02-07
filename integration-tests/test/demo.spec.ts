import { expect } from 'chai'
import assert = require('assert')
import { JsonRpcProvider, TransactionResponse } from '@ethersproject/providers'
import { BigNumber, Contract, Wallet, utils } from 'ethers'
import { getContractInterface } from '@metis.io/contracts'
import { Watcher } from '@eth-optimism/core-utils'
import dotenv = require('dotenv')
import * as path from 'path';

export const getEnvironment = async (): Promise<{
    l1Provider: JsonRpcProvider,
    l2Provider: JsonRpcProvider,
    l1Wallet: Wallet,
    l2Wallet: Wallet,
    AddressManager: Contract,
    watcher: Watcher
}> => {
    const l1Provider = new JsonRpcProvider("http://localhost:9545")
    const l2Provider = new JsonRpcProvider("http://localhost:8545")
    const l1Wallet = new Wallet("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", l1Provider)
    const l2Wallet = new Wallet("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", l2Provider)

    const addressManagerInterface = null
    const AddressManager = null
    const watcher = null
    

    return {
        l1Provider,
        l2Provider,
        l1Wallet,
        l2Wallet,
        AddressManager,
        watcher
    }
}


const MVM_Coinbase_ADDRESS = '0x4200000000000000000000000000000000000006'
const PROXY_SEQUENCER_ENTRYPOINT_ADDRESS = '0x4200000000000000000000000000000000000004'
const TAX_ADDRESS = '0x1234123412341234123412341234123412341234'

let l1Provider: JsonRpcProvider
let l2Provider: JsonRpcProvider
let l1Wallet: Wallet
let l2Wallet: Wallet
let AddressManager: Contract
let watcher: Watcher

describe('Fee Payment Integration Tests', async () => {
  const envPath = path.join(__dirname, '/.env');
  dotenv.config({ path: envPath })
  
  let OVM_L1ETHGateway: Contract
  let MVM_Coinbase: Contract
  let OVM_L2CrossDomainMessenger: Contract

  const getBalances = async ():
    Promise<{
      l1UserBalance: BigNumber,
      l2UserBalance: BigNumber,
      l1GatewayBalance: BigNumber,
      sequencerBalance: BigNumber,
    }> => {
      const l1UserBalance = await l1Wallet.getBalance()
      const l2UserBalance = await MVM_Coinbase.balanceOf(l2Wallet.address)
      const sequencerBalance = await MVM_Coinbase.balanceOf(PROXY_SEQUENCER_ENTRYPOINT_ADDRESS)
      const l1GatewayBalance = await MVM_Coinbase.balanceOf('0x4200000000000000000000000000000000000005')
      return {
        l1UserBalance,
        l2UserBalance,
        l1GatewayBalance,
        sequencerBalance
      }
    }

  before(async () => {
    const system = await getEnvironment()
    l1Provider = system.l1Provider
    l2Provider = system.l2Provider
    l1Wallet = system.l1Wallet
    l2Wallet = system.l2Wallet
    
    const addressManagerAddress = "0x5FbDB2315678afecb367f032d93F642f64180aa3"
    const addressManagerInterface = getContractInterface('Lib_AddressManager')
    const AddressManager = new Contract(addressManagerAddress, addressManagerInterface, l1Provider)
    MVM_Coinbase = new Contract(
      MVM_Coinbase_ADDRESS,
      getContractInterface('MVM_Coinbase'),
      l2Wallet
    )
    
    console.log(await MVM_Coinbase.l1TokenGateway(),
    await AddressManager.getAddress('Proxy__OVM_L1ETHGateway'),
    await AddressManager.getAddress('OVM_L1ETHGateway'),
    await AddressManager.getAddress('OVM_L2BatchMessageRelayer'))
    const l1GatewayInterface = getContractInterface('OVM_L1ETHGateway')
    OVM_L1ETHGateway = new Contract(
      await AddressManager.getAddress('Proxy__OVM_L1ETHGateway'),
      l1GatewayInterface,
      l1Wallet
    )
    OVM_L2CrossDomainMessenger = new Contract(
      '0x4200000000000000000000000000000000000007',
      getContractInterface('OVM_L2CrossDomainMessenger'),
      l2Wallet
    )
  })

  beforeEach(async () => {
    const depositAmount = utils.parseEther('100')
    var postBalances = await getBalances()
    console.log(postBalances.l1UserBalance+","+postBalances.l2UserBalance+","+postBalances.l1GatewayBalance+","+postBalances.sequencerBalance)
    // await waitForDepositTypeTransaction(
    const tx2 =await  OVM_L1ETHGateway.depositToByChainId(429,l2Wallet.address,{
        value: depositAmount,
        gasLimit: '9400000',
        gasPrice: 0
      })
    //   watcher, l1Provider, l2Provider
    // )
    const res=await tx2.wait()
    //console.log(res)
    postBalances = await getBalances()
    console.log(postBalances.l1UserBalance+","+postBalances.l2UserBalance+","+postBalances.l1GatewayBalance+","+postBalances.sequencerBalance)
  })
  

  it('Paying a nonzero but acceptable gasPrice fee', async () => {
    const preBalances = await getBalances()

    const gasPrice = BigNumber.from(15000000)
    const gasLimit = BigNumber.from(167060000)
    //await l2Wallet.sendTransaction({to:PROXY_SEQUENCER_ENTRYPOINT_ADDRESS,value:1000000000000000,gasPrice,gasLimit})
    // transfer with 0 value to easily pay a gas fee
    let res: TransactionResponse = await MVM_Coinbase.transfer(
      PROXY_SEQUENCER_ENTRYPOINT_ADDRESS,
      0.1,
      {
        gasPrice,
        gasLimit
      }
    )
    await res.wait()
    var postBalances = await getBalances()
    console.log("l1 wallet balance:"+postBalances.l1UserBalance+",l2 wallet balance"+postBalances.l2UserBalance+",l1gateway balance"+postBalances.l1GatewayBalance+",seq balance"+postBalances.sequencerBalance)
    // const taxBalance = await MVM_Coinbase.balanceOf(TAX_ADDRESS)
    // console.log("tax balance:"+taxBalance)
    // res = await MVM_Coinbase.withdraw(
    //   1000,
    //   {
    //     gasPrice,
    //     gasLimit
    //   }
    // )
    // await res.wait()
    // var postBalances = await getBalances()
    // console.log("l1 wallet balance:"+postBalances.l1UserBalance+",l2 wallet balance"+postBalances.l2UserBalance+",l1gateway balance"+postBalances.l1GatewayBalance+",seq balance"+postBalances.sequencerBalance)
    
    // // make sure stored and served correctly by geth
    // expect(res.gasPrice.eq(gasPrice)).to.be.true
    // expect(res.gasLimit.eq(gasLimit)).to.be.true

    // postBalances = await getBalances()
    const feePaid = preBalances.l2UserBalance.sub(
      postBalances.l2UserBalance
    )

    expect(
      feePaid.
        eq(
          gasLimit.mul(gasPrice)
        )
    ).to.be.true
  })

  it.skip('sequencer rejects transaction with a non-multiple-of-1M gasPrice', async () => {
    const gasPrice = BigNumber.from(0)
    const gasLimit = BigNumber.from('0x100000')

    let err: string
    try {
      const res = await MVM_Coinbase.transfer(
        '0x1234123412341234123412341234123412341234',
        0,
        {
          gasPrice,
          gasLimit
        }
      )
      await res.wait()
    } catch (e) {
      err = e.body
    }

    if (err === undefined) {
      throw new Error('Transaction did not throw as expected')
    }

    expect(
      err.includes('Gas price must be a multiple of 1,000,000 wei')
    ).to.be.true
  })
})
