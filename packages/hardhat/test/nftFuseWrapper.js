const fs = require('fs')
const chalk = require('chalk')
const { config, ethers } = require('hardhat')
const { utils, BigNumber: BN } = ethers
const { use, expect } = require('chai')
const { solidity } = require('ethereum-waffle')
const n = require('eth-ens-namehash')
const namehash = n.hash
const { loadENSContract } = require('../utils/contracts')
const baseRegistrarJSON = require('./baseRegistrarABI')

use(solidity)

const labelhash = (label) => utils.keccak256(utils.toUtf8Bytes(label))
const ROOT_NODE =
  '0x0000000000000000000000000000000000000000000000000000000000000000'

const addresses = {}

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

describe('NFT fuse wrapper', () => {
  let ENSRegistry
  let BaseRegistrar
  let NFTFuseWrapper
  let PublicResolver
  let SubDomainRegistrar

  before(async () => {
    const [owner] = await ethers.getSigners()
    const registryJSON = loadENSContract('ens', 'ENSRegistry')

    const registryContractFactory = new ethers.ContractFactory(
      registryJSON.abi,
      registryJSON.bytecode,
      owner
    )

    EnsRegistry = await registryContractFactory.deploy()

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

    NFTFuseWrapper = await deploy('NFTFuseWrapper', [
      EnsRegistry.address,
      BaseRegistrar.address,
    ])

    PublicResolver = await deploy('PublicResolver', [
      EnsRegistry.address,
      addresses['NFTFuseWrapper'],
    ])

    SubDomainRegistrar = await deploy('SubdomainRegistrar', [
      EnsRegistry.address,
      addresses['NFTFuseWrapper'],
    ])

    // setup .eth
    await EnsRegistry.setSubnodeOwner(
      ROOT_NODE,
      utils.keccak256(utils.toUtf8Bytes('eth')),
      account
    )

    // setup .xyz
    await EnsRegistry.setSubnodeOwner(
      ROOT_NODE,
      utils.keccak256(utils.toUtf8Bytes('xyz')),
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
      'ens.setApprovalForAll NFTFuseWrapper',
      account,
      addresses['NFTFuseWrapper']
    )

    console.log(
      'ens.setApprovalForAll SubDomainRegistrar',
      SubDomainRegistrar.address,
      true
    )
    await EnsRegistry.setApprovalForAll(SubDomainRegistrar.address, true)

    console.log(
      'NFTFuseWrapper.setApprovalForAll SubDomainRegistrar',
      SubDomainRegistrar.address,
      true
    )
    await NFTFuseWrapper.setApprovalForAll(SubDomainRegistrar.address, true)

    //make sure base registrar is owner of eth TLD

    const ownerOfEth = await EnsRegistry.owner(namehash('eth'))

    expect(ownerOfEth).to.equal(BaseRegistrar.address)
  })
  it('wrap() wraps a name with the ERC721 standard and fuses', async () => {
    const [signer] = await ethers.getSigners()
    const account = await signer.getAddress()

    await BaseRegistrar.register(labelhash('xyz'), account, 84600)
    await EnsRegistry.setApprovalForAll(NFTFuseWrapper.address, true)
    await NFTFuseWrapper.wrap(ROOT_NODE, labelhash('xyz'), 255, account)
    const ownerOfWrappedXYZ = await NFTFuseWrapper.ownerOf(namehash('xyz'))
    expect(ownerOfWrappedXYZ).to.equal(account)
  })

  it('wrap2Ld() wraps a name with the ERC721 standard and fuses', async () => {
    const [signer] = await ethers.getSigners()
    const account = await signer.getAddress()

    await BaseRegistrar.register(labelhash('wrapped2'), account, 84600)

    //allow the restricted name wrappper to transfer the name to itself and reclaim it
    await BaseRegistrar.setApprovalForAll(NFTFuseWrapper.address, true)

    await NFTFuseWrapper.wrapETH2LD(labelhash('wrapped2'), 255, account)

    //make sure reclaim claimed ownership for the wrapper in registry
    const ownerInRegistry = await EnsRegistry.owner(namehash('wrapped2.eth'))

    expect(ownerInRegistry).to.equal(NFTFuseWrapper.address)

    //make sure owner in the wrapper is the user
    const ownerOfWrappedEth = await NFTFuseWrapper.ownerOf(
      namehash('wrapped2.eth')
    )

    expect(ownerOfWrappedEth).to.equal(account)

    // make sure registrar ERC721 is owned by Wrapper
    const ownerInRegistrar = await BaseRegistrar.ownerOf(labelhash('wrapped2'))

    expect(ownerInRegistrar).to.equal(NFTFuseWrapper.address)

    // make sure it can't be unwrapped
    const canUnwrap = await NFTFuseWrapper.canUnwrap(namehash('wrapped2.eth'))
  })

  it('can send ERC721 token to restricted wrapper', async () => {
    const [signer] = await ethers.getSigners()
    const account = await signer.getAddress()
    const tokenId = labelhash('send2contract')
    const wrappedTokenId = namehash('send2contract.eth')

    await BaseRegistrar.register(tokenId, account, 84600)

    const ownerInRegistrar = await BaseRegistrar.ownerOf(tokenId)

    await BaseRegistrar['safeTransferFrom(address,address,uint256)'](
      account,
      NFTFuseWrapper.address,
      tokenId
    )

    const ownerInWrapper = await NFTFuseWrapper.ownerOf(wrappedTokenId)

    expect(ownerInWrapper).to.equal(account)
  })

  it('can set fuses and burn transfer', async () => {
    const [signer, signer2] = await ethers.getSigners()
    const account = await signer.getAddress()
    const account2 = await signer2.getAddress()
    const tokenId = labelhash('fuses3')
    const wrappedTokenId = namehash('fuses3.eth')
    const CAN_DO_EVERYTHING = 0
    const CANNOT_UNWRAP = await NFTFuseWrapper.CANNOT_UNWRAP()

    await BaseRegistrar.register(tokenId, account, 84600)

    await NFTFuseWrapper.wrapETH2LD(
      tokenId,
      CAN_DO_EVERYTHING | CANNOT_UNWRAP,
      account
    )

    const CANNOT_TRANSFER = await NFTFuseWrapper.CANNOT_TRANSFER()

    await NFTFuseWrapper.burnFuses(
      namehash('eth'),
      tokenId,
      CAN_DO_EVERYTHING | CANNOT_TRANSFER
    )

    const ownerInWrapper = await NFTFuseWrapper.ownerOf(wrappedTokenId)

    expect(ownerInWrapper).to.equal(account)

    // check flag in the wrapper
    const canTransfer = await NFTFuseWrapper.canTransfer(wrappedTokenId)

    expect(canTransfer).to.equal(false)

    //try to set the resolver and ttl
    expect(
      NFTFuseWrapper.setOwner(wrappedTokenId, account2)
    ).to.be.revertedWith('revert Fuse already blown for setting owner')
  })

  it('can set fuses and burn canSetData', async () => {
    const [signer] = await ethers.getSigners()
    const account = await signer.getAddress()
    const tokenId = labelhash('fuses1')
    const wrappedTokenId = namehash('fuses1.eth')
    const CAN_DO_EVERYTHING = 0
    const CANNOT_UNWRAP = await NFTFuseWrapper.CANNOT_UNWRAP()

    await BaseRegistrar.register(tokenId, account, 84600)

    await NFTFuseWrapper.wrapETH2LD(
      tokenId,
      CAN_DO_EVERYTHING | CANNOT_UNWRAP,
      account
    )

    const CANNOT_SET_DATA = await NFTFuseWrapper.CANNOT_SET_DATA()

    await NFTFuseWrapper.burnFuses(
      namehash('eth'),
      tokenId,
      CAN_DO_EVERYTHING | CANNOT_SET_DATA
    )

    const ownerInWrapper = await NFTFuseWrapper.ownerOf(wrappedTokenId)

    expect(ownerInWrapper).to.equal(account)

    // check flag in the wrapper
    const canSetData = await NFTFuseWrapper.canSetData(wrappedTokenId)

    expect(canSetData).to.equal(false)

    //try to set the resolver and ttl
    expect(
      NFTFuseWrapper.setResolver(wrappedTokenId, account)
    ).to.be.revertedWith('revert Fuse already blown for setting resolver')

    expect(NFTFuseWrapper.setTTL(wrappedTokenId, 1000)).to.be.revertedWith(
      'revert Fuse already blown for setting TTL'
    )
  })

  it('can set fuses and burn canCreateSubdomains', async () => {
    const [signer] = await ethers.getSigners()
    const account = await signer.getAddress()
    const tokenId = labelhash('fuses2')
    const wrappedTokenId = namehash('fuses2.eth')
    const CAN_DO_EVERYTHING = 0
    const CANNOT_UNWRAP = await NFTFuseWrapper.CANNOT_UNWRAP()
    const CANNOT_REPLACE_SUBDOMAIN = await NFTFuseWrapper.CANNOT_REPLACE_SUBDOMAIN()
    const CANNOT_CREATE_SUBDOMAIN = await NFTFuseWrapper.CANNOT_CREATE_SUBDOMAIN()

    await BaseRegistrar.register(tokenId, account, 84600)

    await NFTFuseWrapper.wrapETH2LD(
      tokenId,
      CAN_DO_EVERYTHING | CANNOT_UNWRAP | CANNOT_REPLACE_SUBDOMAIN,
      account
    )

    const canCreateSubdomain1 = await NFTFuseWrapper.canCreateSubdomain(
      wrappedTokenId
    )

    expect(canCreateSubdomain1, 'createSubdomain is set to false').to.equal(
      true
    )

    console.log('canCreateSubdomain before burning', canCreateSubdomain1)

    // can create before burn

    //revert not approved and isn't sender because subdomain isnt owned by contract?
    await NFTFuseWrapper.setSubnodeOwnerAndWrap(
      wrappedTokenId,
      labelhash('creatable'),
      account,
      255
    )

    expect(
      await NFTFuseWrapper.ownerOf(namehash('creatable.fuses2.eth'))
    ).to.equal(account)

    await NFTFuseWrapper.burnFuses(
      namehash('eth'),
      tokenId,
      CAN_DO_EVERYTHING | CANNOT_CREATE_SUBDOMAIN
    )

    const ownerInWrapper = await NFTFuseWrapper.ownerOf(wrappedTokenId)

    expect(ownerInWrapper).to.equal(account)

    const canCreateSubdomain = await NFTFuseWrapper.canCreateSubdomain(
      wrappedTokenId
    )

    expect(canCreateSubdomain).to.equal(false)

    //try to create a subdomain

    expect(
      NFTFuseWrapper.setSubnodeOwner(
        namehash('fuses2.eth'),
        labelhash('uncreateable'),
        account
      )
    ).to.be.revertedWith(
      'revert The fuse has been burned for creating or replace a subdomain'
    )

    //expect replacing subdomain to succeed
  })
})
// TODO move these tests to separate repo
// describe('SubDomainRegistrar configureDomain', () => {
//   it('Should be able to configure a new domain', async () => {
//     const [owner] = await ethers.getSigners()
//     const account = await owner.getAddress()
//     await BaseRegistrar.register(labelhash('vitalik'), account, 84600)
//     await SubDomainRegistrar.configureDomain(
//       namehash('eth'),
//       labelhash('vitalik'),
//       '1000000',
//       0
//     )

//     // TODO: assert vitalik.eth has been configured
//   })

//   it('Should be able to configure a new domain and then register', async () => {
//     const [signer] = await ethers.getSigners()
//     const account = await signer.getAddress()

//     await BaseRegistrar.register(labelhash('ens'), account, 84600)

//     await SubDomainRegistrar.configureDomain(
//       namehash('eth'),
//       labelhash('ens'),
//       '1000000',
//       0
//     )

//     const tx = PublicResolver.interface.encodeFunctionData(
//       'setAddr(bytes32,uint256,bytes)',
//       [namehash('awesome.ens.eth'), 60, account]
//     )

//     await SubDomainRegistrar.register(
//       namehash('ens.eth'),
//       'awesome',
//       account,
//       account,
//       addresses['PublicResolver'],
//       [tx],
//       {
//         value: '1000000',
//       }
//     )
//   })

//   it('Should be able to configure a new domain and then register fails because namehash does not match', async () => {
//     const [signer] = await ethers.getSigners()
//     const account = await signer.getAddress()

//     const tx = PublicResolver.interface.encodeFunctionData(
//       'setAddr(bytes32,uint256,bytes)',
//       [namehash('awesome.ens.eth'), 60, account]
//     )

//     //should fail as tx is not correct
//     await expect(
//       SubDomainRegistrar.register(
//         namehash('ens.eth'),
//         'othername',
//         account,
//         account,
//         addresses['PublicResolver'],
//         [tx],
//         {
//           value: '1000000',
//         }
//       )
//     ).to.be.revertedWith('revert invalid node for multicall')
//   })
// })
//         addresses['PublicResolver'],
//         [tx],
//         {
//           value: '1000000',
//         }
//       )
//     ).to.be.revertedWith('revert invalid node for multicall')
//   })
// })
