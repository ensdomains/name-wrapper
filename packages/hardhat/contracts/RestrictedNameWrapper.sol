import "../interfaces/ENS.sol";
import "../interfaces/BaseRegistrar.sol";
import "../interfaces/Resolver.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../interfaces/IRestrictedNameWrapper.sol";
import "hardhat/console.sol";

contract RestrictedNameWrapper is ERC721, IRestrictedNameWrapper {
    ENS public ens;
    bytes32
        public constant ETH_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    mapping(bytes32 => uint256) public fuses;

    constructor(ENS _ens) ERC721("ENS Name", "ENS") {
        ens = _ens;
    }

    modifier ownerOnly(bytes32 node) {
        require(isOwnerOrApproved(node, msg.sender));
        _;
    }

    function isOwnerOrApproved(bytes32 node, address addr)
        public
        override
        view
        returns (bool)
    {
        //memory owner = ;
        return
            ownerOf(uint256(node)) == addr ||
            isApprovedForAll(ownerOf(uint256(node)), addr);
    }

    function canUnwrap(bytes32 node) public view returns (bool) {
        return fuses[node] & CAN_UNWRAP != 0;
    }

    function canSetTTL(bytes32 node) public view returns (bool) {
        //return fuses[node] & CAN_UNWRAP != 0 || fuses[node] & CAN_SET_TTL != 0;
        return fuses[node] & (CAN_UNWRAP | CAN_SET_TTL) != 0;
    }

    //00001 | 10000 = 10001 // create a bitmask

    function canSetResolver(bytes32 node) public view returns (bool) {
        return fuses[node] & (CAN_UNWRAP | CAN_SET_RESOLVER) != 0;
    }

    function canCreateSubdomain(bytes32 node) public view returns (bool) {
        return fuses[node] & (CAN_UNWRAP | CAN_CREATE_SUBDOMAIN) != 0;
    }

    function canReplaceSubdomain(bytes32 node) public view returns (bool) {
        return fuses[node] & (CAN_UNWRAP | CAN_REPLACE_SUBDOMAIN) != 0;
    }

    /**
     * @dev Mint Erc721 for the subdomain
     * @param id The token ID (keccak256 of the label).
     * @param subdomainOwner The address that should own the registration.
     * @param tokenURI tokenURI address
     */

    function mintERC721(
        uint256 id,
        address subdomainOwner,
        string memory tokenURI
    ) private returns (uint256) {
        _mint(subdomainOwner, id);
        _setTokenURI(id, tokenURI);
        return id;
    }

    function wrapETH2LD(
        uint256 tokenId,
        uint256 _fuses,
        address wrappedOwner
    ) public {
        BaseRegistrar registrar = BaseRegistrar(ens.owner(ETH_NODE));
        // BaseRegistrar.transferFrom(tokenId, address(this));
        // BaseRegistrar.reclaim(tokenId, address(this))
        // wrap()
        // auto burn canUnwrap
    }

    function wrap(
        bytes32 parentNode,
        bytes32 label,
        uint256 _fuses,
        address wrappedOwner
    ) public override {
        //check if the parent is !canReplaceSubdomain(node) if is, do the fuse, else, all not burned
        if (canReplaceSubdomain(parentNode)) {
            _fuses = CAN_DO_EVERYTHING;
        }
        bytes32 node = keccak256(abi.encodePacked(parentNode, label));
        fuses[node] = _fuses;
        address owner = ens.owner(node);
        console.log("owner");
        console.log(owner);
        require(
            owner == msg.sender || ens.isApprovedForAll(owner, msg.sender),
            "not approved and isn't sender"
        );
        ens.setOwner(node, address(this));
        mintERC721(uint256(node), wrappedOwner, ""); //TODO add URI
    }

    function unwrap(bytes32 node, address owner)
        public
        override
        ownerOnly(node)
    {
        require(canUnwrap(node), "Domain is unwrappable");

        //set fuses back to normal - not sure if we need this?
        fuses[node] = 0;
        _burn(uint256(node));
        ens.setOwner(node, owner);
    }

    function burnFuses(
        bytes32 node,
        bytes32 label,
        uint256 _fuses
    ) public ownerOnly(node) {
        // Check parent domain. Can't clear the flag if the parent hasn't been burned canUnwrap/. Error
        BaseRegistrar registrar = BaseRegistrar(ens.owner(ETH_NODE));
        require(
            !canReplaceSubdomain(node) ||
                (registrar.ownerOf(uint256(label)) == address(this) &&
                    node == ETH_NODE)
        );
        bytes32 subnode = keccak256(abi.encodePacked(node, label));
        fuses[subnode] &= _fuses;
    }

    function setRecord(
        bytes32 node,
        address owner,
        address resolver,
        uint64 ttl
    ) external {
        require(canSetResolver(node) && canSetTTL(node));
        setResolver(node, resolver);
        setTTL(node, ttl);
        setOwner(node, owner);
    }

    function setSubnodeRecord(
        bytes32 node,
        bytes32 label,
        address addr,
        address resolver,
        uint64 ttl
    ) public ownerOnly(node) {
        bytes32 subnode = keccak256(abi.encodePacked(node, label));
        address owner = ens.owner(subnode);
        require(
            (owner == address(0) && canCreateSubdomain(node)) ||
                (owner != address(0) && canReplaceSubdomain(node))
        );
        //TODO repeat this on setSubnodeOwner()

        return ens.setSubnodeRecord(node, label, addr, resolver, ttl);
    }

    function setSubnodeOwner(
        bytes32 node,
        bytes32 label,
        address owner
    ) public override ownerOnly(node) returns (bytes32) {
        bytes32 subnode = keccak256(abi.encodePacked(node, label));

        require(ens.owner(subnode) == address(0) || canReplaceSubdomain(node));
        ens.setSubnodeOwner(node, label, owner);
    }

    function setSubnodeRecordAndWrap(
        bytes32 node,
        bytes32 label,
        address owner,
        address resolver,
        uint64 ttl,
        uint256 _fuses
    ) public override returns (bytes32) {
        setSubnodeRecord(node, label, owner, resolver, ttl);
        wrap(node, label, _fuses, owner);
    }

    function setResolver(bytes32 node, address resolver)
        public
        override
        ownerOnly(node)
    {
        console.log("node");
        console.logBytes32(node);
        require(
            canSetResolver(node),
            "Fuse already blown for setting resolver"
        );
        ens.setResolver(node, resolver);
    }

    function setOwner(bytes32 node, address owner)
        public
        override
        ownerOnly(node)
    {
        safeTransferFrom(msg.sender, owner, uint256(node));
    }

    function setTTL(bytes32 node, uint64 ttl) public ownerOnly(node) {
        require(canSetTTL(node), "Fuse already blown for setting TTL");
        ens.setTTL(node, ttl);
    }
}

// 1. ETHRegistrarController.commit()
// 2. ETHRegistrarController.registerWithConfig()
// 3. SubdomainRegistrar.configure()

// a. ENS.setApprovalForAll(SubdomainRegistrar, true)
// b. RestrictiveWrapper.setApprovaForAll(SubdomainRegistrar, true)

// Nick's feedback

// remove ERC721 from OpenZeppelin and make our own

// minting takes 120k more gas. Check for another ERC721 contract that is lighter weight.

// When checking canUnwrap - need to ch
// When calling

// Options for wrapping. Approve Wrapper + wrap. Use ERC721 onERC721Received hook and add calldata to wrap it (safeTransferFrom)
// Do both safety
// Write the wrapped function
// Send ETH Registrar token to ourselves, so we have control over it (burn). Identify if node is .eth

//Combine CAN_SET_RESOLVER and CAN_SET_TTL to one fuse
// Add events so subgraph can track

//Registry for own fuse
