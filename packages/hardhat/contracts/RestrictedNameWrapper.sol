import "../interfaces/ENS.sol";
import "../interfaces/Resolver.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../interfaces/IRestrictedNameWrapper.sol";
import "hardhat/console.sol";

// todo
// add ERC721
// change ownership to use erc721
// mint token on wrap

contract RestrictedNameWrapper is ERC721, IRestrictedNameWrapper {
    ENS public ens;
    mapping(bytes32 => uint256) public fuses;

    constructor(ENS _ens) public ERC721("ENS Name", "ENS") {
        ens = _ens;
    }

    modifier ownerOnly(bytes32 node) {
        require(isOwnerOrApproved(node, msg.sender));
        _;
    }

    function isOwnerOrApproved(bytes32 node, address addr)
        public
        override
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

    function wrap(
        bytes32 node,
        uint256 _fuses,
        address wrappedOwner
    ) public override {
        fuses[node] = _fuses;
        address owner = ens.owner(node);
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

    function burnFuses(bytes32 node, uint256 _fuses) public ownerOnly(node) {
        fuses[node] &= _fuses;
    }

    function setSubnodeRecordAndWrap(
        bytes32 node,
        bytes32 label,
        address owner,
        address resolver,
        uint64 ttl
    ) external {
        setSubnodeRecord(node, label, address(this), resolver, ttl);
        mintERC721(uint256(node), owner, "");
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
        address owner,
        address resolver,
        uint64 ttl
    ) public ownerOnly(node) {
        bytes32 subnode = keccak256(abi.encodePacked(node, label));
        if (canCreateSubdomain(node) && canReplaceSubdomain(node)) {
            return ens.setSubnodeRecord(node, label, owner, resolver, ttl);
        } else if (canCreateSubdomain(node)) {
            require(
                ens.owner(subnode) == address(0),
                "Subdomain already registered"
            );
            return ens.setSubnodeRecord(node, label, owner, resolver, ttl);
        }
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
        bytes32 subnode = keccak256(abi.encodePacked(node, label));
        setSubnodeRecord(node, label, owner, resolver, ttl);
        wrap(subnode, _fuses, owner);
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
