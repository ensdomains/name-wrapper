const fs = require('fs')
const chalk = require('chalk')
const { config, ethers } = require('hardhat')
const { utils, BigNumber: BN } = ethers
const { use, expect } = require('chai')
const { solidity } = require('ethereum-waffle')
const n = require('eth-ens-namehash')
const namehash = n.hash
const { loadENSContract } = require('../utils/contracts')

use(solidity)

const labelhash = (label) => utils.keccak256(utils.toUtf8Bytes(label))

const addresses = {}

const NO_AUTO_DEPLOY = [
  'PublicResolver.sol',
  'SubdomainRegistrar.sol',
  'RestrictedNameWrapper.sol',
]

function readArgumentsFile(contractName) {
  let args = []
  try {
    const argsFile = `./contracts/${contractName}.args`
    if (fs.existsSync(argsFile)) {
      args = JSON.parse(fs.readFileSync(argsFile))
    }
  } catch (e) {
    console.log(e)
  }

  return args
}

const isSolidity = (fileName) =>
  fileName.indexOf('.sol') >= 0 && fileName.indexOf('.swp.') < 0

async function autoDeploy() {
  const contractList = fs.readdirSync(config.paths.sources)
  return contractList
    .filter((fileName) => {
      if (NO_AUTO_DEPLOY.includes(fileName)) {
        //don't auto deploy this list of Solidity files
        return false
      }
      return isSolidity(fileName)
    })
    .reduce((lastDeployment, fileName) => {
      const contractName = fileName.replace('.sol', '')
      const args = readArgumentsFile(contractName)

      // Wait for last deployment to complete before starting the next
      return lastDeployment.then((resultArrSoFar) =>
        deploy(contractName, args).then((result) => [...resultArrSoFar, result])
      )
    }, Promise.resolve([]))
}

async function deploy(name, _args) {
  const args = _args || []

  console.log(`📄 ${name}`)
  const contractArtifacts = await ethers.getContractFactory(name)
  const contract = await contractArtifacts.deploy(...args)
  console.log(chalk.cyan(name), 'deployed to:', chalk.magenta(contract.address))
  fs.writeFileSync(`artifacts/${name}.address`, contract.address)
  console.log('\n')
  contract.name = name
  addresses[name] = contract.address
  return contract
}

describe('Subdomain Registrar and Wrapper', () => {
  let ENSRegistry
  let BaseRegistrar
  let EthRegistrarController
  let RestrictedNameWrapper
  let PublicResolver
  let SubDomainRegistrar
  let LinearPriceOracle

  describe('SubdomainRegistrar', () => {
    it('Should deploy ENS contracts', async () => {
      const [owner] = await ethers.getSigners()
      const registryJSON = loadENSContract('ens', 'ENSRegistry')
      const baseRegistrarJSON = loadENSContract(
        'ethregistrar',
        'BaseRegistrarImplementation'
      )
      const controllerJSON = loadENSContract(
        'ethregistrar',
        'ETHRegistrarController'
      )
      const dummyOracleJSON = loadENSContract('ethregistrar', 'DummyOracle')
      const linearPremiumPriceOracleJSON = loadENSContract(
        'ethregistrar',
        'LinearPremiumPriceOracle'
      )

      const registryContractFactory = new ethers.ContractFactory(
        registryJSON.abi,
        registryJSON.bytecode,
        owner
      )
      EnsRegistry = await registryContractFactory.deploy()

      const ROOT_NODE =
        '0x0000000000000000000000000000000000000000000000000000000000000000'

      try {
        const rootOwner = await EnsRegistry.owner(ROOT_NODE)
      } catch (e) {
        console.log('failing on rootOwner', e)
      }
      console.log('succeeded on root owner')
      const account = await owner.getAddress()

      BaseRegistrar = await new ethers.ContractFactory(
        baseRegistrarJSON.abi,
        baseRegistrarJSON.bytecode,
        owner
      ).deploy(EnsRegistry.address, namehash('eth'))

      console.log(`*** BaseRegistrar deployed at ${BaseRegistrar.address} *** `)

      await BaseRegistrar.addController(account)

      console.log(
        `*** BaseRegistrar.addController() -- Added account ${account} *** `
      )

      DummyOracle = await new ethers.ContractFactory(
        dummyOracleJSON.abi,
        dummyOracleJSON.bytecode,
        owner
      ).deploy('20000000000')

      console.log('*** DummyOracle deployed *** ')

      const latestAnswer = await DummyOracle.latestAnswer()
      console.log(latestAnswer.toString())

      console.log('Dummy USD Rate', { latestAnswer })
      // Premium starting price: 10 ETH = 2000 USD
      const premium = BN.from('2000000000000000000000') // 2000 * 1e18
      const decreaseDuration = BN.from(28 * 24 * 60 * 60)
      const decreaseRate = premium.div(decreaseDuration)

      LinearPriceOracle = await new ethers.ContractFactory(
        linearPremiumPriceOracleJSON.abi,
        linearPremiumPriceOracleJSON.bytecode,
        owner
      ).deploy(
        DummyOracle.address,
        // Oracle prices from https://etherscan.io/address/0xb9d374d0fe3d8341155663fae31b7beae0ae233a#events
        // 0,0, 127, 32, 1
        [
          0,
          0,
          BN.from(20294266869609),
          BN.from(5073566717402),
          BN.from(158548959919),
        ],
        premium,
        decreaseRate
      )

      console.log('*** Linear Price Oracle deployed *** ')

      EthRegistrarController = await new ethers.ContractFactory(
        controllerJSON.abi,
        controllerJSON.bytecode,
        owner
      ).deploy(
        BaseRegistrar.address,
        LinearPriceOracle.address,
        2, // 10 mins in seconds
        86400 // 24 hours in seconds
      )

      console.log('*** EthRegistrarController deployed *** ')

      // const newController = await deploy(
      //   web3,
      //   accounts[0],
      //   controllerJSON,
      //   newBaseRegistrar._address,
      //   linearPriceOracle._address,
      //   2, // 10 mins in seconds
      //   86400 // 24 hours in seconds
      // )
      // const newControllerContract = newController.methods

      RestrictedNameWrapper = await deploy('RestrictedNameWrapper', [
        EnsRegistry.address,
        BaseRegistrar.address,
      ])

      PublicResolver = await deploy('PublicResolver', [
        EnsRegistry.address,
        addresses['RestrictedNameWrapper'],
      ])

      SubDomainRegistrar = await deploy('SubdomainRegistrar', [
        EnsRegistry.address,
        addresses['RestrictedNameWrapper'],
      ])

      // setup .eth
      await EnsRegistry.setSubnodeOwner(
        ROOT_NODE,
        utils.keccak256(utils.toUtf8Bytes('eth')),
        account
      )

      // give .eth back to registrar

      // make base registrar owner of eth
      await EnsRegistry.setSubnodeOwner(
        ROOT_NODE,
        labelhash('eth'),
        BaseRegistrar.address
      )

      const ethOwner = await EnsRegistry.owner(namehash('eth'))
      const ensEthOwner = await EnsRegistry.owner(namehash('ens.eth'))

      console.log('ethOwner', ethOwner)
      console.log('ensEthOwner', ensEthOwner)

      console.log(
        'ens.setApprovalForAll RestrictedNameWrapper',
        account,
        addresses['RestrictedNameWrapper']
      )
      // // make wrapper approved for account owning ens.eth
      // await EnsRegistry.setApprovalForAll(addresses['RestrictedNameWrapper'], true)

      console.log(
        'ens.setApprovalForAll SubDomainRegistrar',
        SubDomainRegistrar.address,
        true
      )
      await EnsRegistry.setApprovalForAll(SubDomainRegistrar.address, true)

      console.log(
        'RestrictedNameWrapper.setApprovalForAll SubDomainRegistrar',
        SubDomainRegistrar.address,
        true
      )
      await RestrictedNameWrapper.setApprovalForAll(
        SubDomainRegistrar.address,
        true
      )

      //make sure base registrar is owner of eth TLD

      const ownerOfEth = await EnsRegistry.owner(namehash('eth'))

      expect(ownerOfEth).to.equal(BaseRegistrar.address)
    })

    describe('SubDomainRegistrar configureDomain', () => {
      it('Should be able to configure a new domain', async () => {
        const [owner] = await ethers.getSigners()
        const account = await owner.getAddress()
        await BaseRegistrar.register(labelhash('vitalik'), account, 84600)
        await SubDomainRegistrar.configureDomain(
          namehash('eth'),
          labelhash('vitalik'),
          '1000000',
          0
        )

        // TODO: assert vitalik.eth has been configured
      })

      it('Should be able to configure a new domain and then register', async () => {
        const [signer] = await ethers.getSigners()
        const account = await signer.getAddress()

        await BaseRegistrar.register(labelhash('ens'), account, 84600)

        await SubDomainRegistrar.configureDomain(
          namehash('eth'),
          labelhash('ens'),
          '1000000',
          0
        )

        const tx = PublicResolver.interface.encodeFunctionData(
          'setAddr(bytes32,uint256,bytes)',
          [namehash('awesome.ens.eth'), 60, account]
        )

        await SubDomainRegistrar.register(
          namehash('ens.eth'),
          'awesome',
          account,
          account,
          addresses['PublicResolver'],
          [tx],
          {
            value: '1000000',
          }
        )
      })

      it('Should be able to configure a new domain and then register fails because namehash does not match', async () => {
        const [signer] = await ethers.getSigners()
        const account = await signer.getAddress()

        const tx = PublicResolver.interface.encodeFunctionData(
          'setAddr(bytes32,uint256,bytes)',
          [namehash('awesome.ens.eth'), 60, account]
        )

        //should fail as tx is not correct
        await expect(
          SubDomainRegistrar.register(
            namehash('ens.eth'),
            'othername',
            account,
            account,
            addresses['PublicResolver'],
            [tx],
            {
              value: '1000000',
            }
          )
        ).to.be.revertedWith('revert invalid node for multicall')
      })
    })

    describe('RestrictedNameWrapper', () => {
      it('wrap() wraps a name with the ERC721 standard and fuses', async () => {
        const [signer] = await ethers.getSigners()
        const account = await signer.getAddress()

        //TODO change to register via registrar
        // await EnsRegistry.setSubnodeOwner(
        //   namehash('eth'),
        //   labelhash('wrapped'),
        //   account
        // )

        await BaseRegistrar.register(labelhash('wrapped'), account, 84600)
        await EnsRegistry.setApprovalForAll(RestrictedNameWrapper.address, true)
        await RestrictedNameWrapper.wrap(
          namehash('eth'),
          labelhash('wrapped'),
          255,
          account
        )
        const ownerOfWrappedEth = await RestrictedNameWrapper.ownerOf(
          namehash('wrapped.eth')
        )
        expect(ownerOfWrappedEth).to.equal(account)
      })

      it('wrap2Ld() wraps a name with the ERC721 standard and fuses', async () => {
        const [signer] = await ethers.getSigners()
        const account = await signer.getAddress()

        await BaseRegistrar.register(labelhash('wrapped2'), account, 84600)

        //allow the restricted name wrappper to transfer the name to itself and reclaim it
        await BaseRegistrar.setApprovalForAll(
          RestrictedNameWrapper.address,
          true
        )

        await RestrictedNameWrapper.wrapETH2LD(
          labelhash('wrapped2'),
          255,
          account
        )

        const ownerInRegistry = await EnsRegistry.owner(
          namehash('wrapped2.eth')
        )

        //make sure reclaim claimed ownership for the wrapper in registry
        expect(ownerInRegistry).to.equal(RestrictedNameWrapper.address)
        const ownerOfWrappedEth = await RestrictedNameWrapper.ownerOf(
          namehash('wrapped2.eth')
        )

        //make sure owner in the wrapper is the user

        expect(ownerOfWrappedEth).to.equal(account)
        const ownerInRegistrar = await BaseRegistrar.ownerOf(
          labelhash('wrapped2')
        )

        // make sure registrar ERC721 has been burned
        expect(ownerInRegistrar).to.equal(
          '0x000000000000000000000000000000000000dEaD'
        )

        // make sure it can't be unwrapped
        const canUnwrap = await RestrictedNameWrapper.canUnwrap(
          namehash('wrapped2.eth')
        )
        console.log(canUnwrap)
      })
    })
  })
})
