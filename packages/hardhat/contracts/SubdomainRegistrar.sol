pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "../interfaces/ENS.sol";
import "../interfaces/Resolver.sol";
import "../interfaces/ISubdomainRegistrar.sol";
import "../interfaces/IRestrictedNameWrapper.sol";

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

struct Domain {
    uint256 price;
    uint256 referralFeePPM;
}

// SPDX-License-Identifier: MIT
contract SubdomainRegistrar is ISubdomainRegistrar {
    // namehash('eth')
    bytes32
        public constant TLD_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    bool public stopped = false;
    address public registrarOwner;
    address public migration;
    address public registrar;
    mapping(bytes32 => Domain) domains;

    ENS public ens;
    IRestrictedNameWrapper public wrapper;

    modifier ownerOnly(bytes32 node) {
        address owner = wrapper.ownerOf(uint256(node));
        require(
            owner == msg.sender || wrapper.isApprovedForAll(owner, msg.sender),
            "Not owner"
        ); //TODO fix only owner
        _;
    }

    modifier notStopped() {
        require(!stopped);
        _;
    }

    modifier registrarOwnerOnly() {
        require(msg.sender == registrarOwner);
        _;
    }

    constructor(ENS _ens, IRestrictedNameWrapper _wrapper) public {
        ens = _ens;
        wrapper = _wrapper;
        ens.setApprovalForAll(address(wrapper), true);
    }

    function configureDomain(
        bytes32 node,
        uint256 price,
        uint256 referralFeePPM
    ) public {
        Domain storage domain = domains[node];

        //check if I'm the owner
        if (ens.owner(node) != address(wrapper)) {
            ens.setOwner(node, address(this));
            wrapper.wrap(node, 255, msg.sender);
            console.log(
                "wrapper.ownerOf(uint256(node))",
                wrapper.ownerOf(uint256(node))
            );
        }
        //if i'm in the owner, do nothing
        //otherwise makes myself the owner

        // if (domain.owner != _owner) {
        //     domain.owner = _owner;
        // }

        domain.price = price;
        domain.referralFeePPM = referralFeePPM;

        emit DomainConfigured(node);
    }

    // function doRegistration(
    //     bytes32 node,
    //     bytes32 label,
    //     address subdomainOwner,
    //     Resolver resolver,
    //     bytes[] memory data
    // ) internal {
    //     // Get the subdomain so we can configure it
    //     console.log("doRegistration", address(this));
    //     wrapper.setSubnodeRecordAndWrap(
    //         node,
    //         label,
    //         address(this),
    //         address(resolver),
    //         0,
    //         255
    //     );
    //     //set the owner to this contract so it can setAddr()

    //     bytes32 subnode = keccak256(abi.encodePacked(node, label));
    //     address owner = ens.owner(subnode);
    //     console.log("owner in registry", owner);'
    //     wrapper.setOwner(subnode, subdomainOwner);

    //     // Problem - Current Public Resolver checks ENS registry for ownership. Owner will be the Restrivtve Wrapper
    //     // Possible solution A - use PublicResolver that knows how to check Restrictive Wrapper
    //     // Possible solution B - Deploy an OwnerResolver for each subdomain name
    //     // Possible solution C - Separate Public Resolver that uses Restrictive Name Wrapper
    //     // Possible solution D - wrap setAuthorisation inside RestrictedWrapper - X (don't want the wrapper to know about resolvers)

    //     // Set the address record on the resolver
    //     // console.log("setAuthorisationForResolver");
    //     // wrapper.setAuthorisationForResolver(
    //     //     subnode,
    //     //     address(this),
    //     //     true,
    //     //     resolver
    //     // );
    //     // console.log("setAuthorisationForResolver");
    //     // wrapper.setAuthorisationForResolver(
    //     //     subnode,
    //     //     address(owner),
    //     //     true,
    //     //     resolver
    //     // );
    //     // check calldata for
    //     // if (resolver.checkCallData(node, data)) {
    //     //     resolver.multicall(subnode, data);
    //     // }
    //     address addrVar = resolver.addr(subnode);
    //     console.log(addrVar);
    //     // Currently fails as owner is stil the Restrictive Wrapper

    //     // check if the address is != 0 and then set addr
    //     // reason to check some resolvers don't have setAddr

    //     // Pass ownership of the new subdomain to the registrant
    //     wrapper.setOwner(subnode, subdomainOwner);
    // }

    function register(
        bytes32 node,
        string calldata subdomain,
        address _subdomainOwner,
        address payable referrer,
        address resolver,
        bytes[] calldata data
    ) external override payable notStopped {
        address subdomainOwner = _subdomainOwner;
        bytes32 subdomainLabel = keccak256(bytes(subdomain));

        // Subdomain must not be registered already.
        require(
            ens.owner(keccak256(abi.encodePacked(node, subdomainLabel))) ==
                address(0),
            "Subdomain already registered"
        );

        Domain storage domain = domains[node];

        // Domain must be available for registration
        //require(keccak256(abi.encodePacked(domain.name)) == label);

        // User must have paid enough
        require(msg.value >= domain.price, "Not enough ether provided");

        // // Send any extra back
        if (msg.value > domain.price) {
            msg.sender.transfer(msg.value - domain.price);
        }

        // // Send any referral fee
        uint256 total = domain.price;
        if (
            domain.referralFeePPM * domain.price > 0 &&
            referrer != address(0x0) &&
            referrer != wrapper.ownerOf(uint256(node))
        ) {
            uint256 referralFee = (domain.price * domain.referralFeePPM) /
                1000000;
            referrer.transfer(referralFee);
            total -= referralFee;
        }

        // // Send the registration fee
        // if (total > 0) {
        //     domain.owner.transfer(total);
        // }

        // Register the domain
        if (subdomainOwner == address(0x0)) {
            subdomainOwner = msg.sender;
        }

        wrapper.setSubnodeRecordAndWrap(
            node,
            subdomainLabel,
            address(this),
            address(resolver),
            0,
            255
        );
        //set the owner to this contract so it can setAddr()

        bytes32 subnode = keccak256(abi.encodePacked(node, subdomainLabel));
        address owner = ens.owner(subnode);
        console.log("owner in registry", owner);
        Resolver resolverInstance = Resolver(resolver);
        console.log("data.length");
        console.log(data.length);
        if (data.length > 0) {
            require(
                resolverInstance.checkCallData(subnode, data),
                "calldata incorrect"
            );
            resolverInstance.multicall(data);
        }

        wrapper.setOwner(subnode, subdomainOwner);

        // Commenting out for now because of following error:
        // "CompilerError: Stack too deep, try removing local variables"

        // emit NewRegistration(
        //     node,
        //     subdomain,
        //     subdomainOwner,
        //     referrer,
        //     domain.price
        // );
    }

    /**
     * @dev Mint Erc721 for the subdomain
     * @param id The token ID (keccak256 of the label).
     * @param subdomainOwner The address that should own the registration.
     * @param tokenURI tokenURI address
     */
}

// interface IRestrictedNameWrapper {
//     function wrap(bytes32 node) external;
// }
