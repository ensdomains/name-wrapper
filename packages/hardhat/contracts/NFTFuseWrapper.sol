import "../interfaces/ENS.sol";
import "../interfaces/BaseRegistrar.sol";
import "../interfaces/Resolver.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../interfaces/INFTFuseWrapper.sol";
import "hardhat/console.sol";

contract NFTFuseWrapper is ERC721, IERC721Receiver, INFTFuseWrapper {
    ENS public ens;
    BaseRegistrar public registrar;
    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    bytes32 public constant ETH_NODE =
        0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;
    bytes32 public constant ROOT_NODE =
        0x0000000000000000000000000000000000000000000000000000000000000000;

    mapping(bytes32 => uint256) public fuses;

    constructor(ENS _ens, BaseRegistrar _registrar) ERC721("ENS Name", "ENS") {
        ens = _ens;
        registrar = _registrar;
    }

    modifier ownerOnly(bytes32 node) {
        require(isOwnerOrApproved(node, msg.sender));
        _;
    }

    function isOwnerOrApproved(bytes32 node, address addr)
        public
        view
        override
        returns (bool)
    {
        //memory owner = ;
        return
            ownerOf(uint256(node)) == addr ||
            isApprovedForAll(ownerOf(uint256(node)), addr);
    }

    function canUnwrap(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_UNWRAP == 0;
    }

    // 00000 & 00001

    //00001 | 10000 = 10001 // create a bitmask

    function canSetData(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_SET_DATA == 0;
    }

    function canCreateSubdomain(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_CREATE_SUBDOMAIN == 0;
    }

    // I can only do this if CANNOT_UNWRAP is burned AND CANNOT_CREATE_SUBDOMAIN is burned
    //
    // 00001 & 00001 | 00100

    function canReplaceSubdomain(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_REPLACE_SUBDOMAIN == 0;
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
        bytes32 label,
        uint256 _fuses,
        address wrappedOwner
    ) public override {
        // create the namehash for the name using .eth and the label
        bytes32 node = keccak256(abi.encodePacked(ETH_NODE, label));

        //set fuses
        fuses[node] = _fuses;

        // wrapped token uses whole node
        uint256 wrapperTokenId = uint256(node);

        // .eth registar uses the labelhash of the node
        uint256 tokenId = uint256(label);

        // transfer the token from the user to this contract
        address currentOwner = registrar.ownerOf(tokenId);
        registrar.transferFrom(currentOwner, address(this), tokenId);

        // transfer the ens record back to the new owner (this contract)
        registrar.reclaim(tokenId, address(this));

        // mint a new ERC721 token
        mintERC721(wrapperTokenId, wrappedOwner, "");
    }

    function wrap(
        bytes32 parentNode,
        bytes32 label,
        uint256 _fuses,
        address wrappedOwner
    ) public override {
        //check if the parent is !canReplaceSubdomain(node) if is, do the fuse, else, all not burned

        //TODO uncomment later
        // require(
        //     parentNode != ETH_NODE,
        //     ".eth domains need to use the wrapETH2LD"
        // );
        require(
            !canReplaceSubdomain(parentNode) || parentNode == ETH_NODE,
            "Parent node needs to burn fuse for CANNOT_REPLACE_SUBDOMAIN first"
        );
        bytes32 node = keccak256(abi.encodePacked(parentNode, label));
        fuses[node] = _fuses;
        address owner = ens.owner(node);

        require(owner == msg.sender, "Domain is not owned by the sender");
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
    ) public ownerOnly(keccak256(abi.encodePacked(node, label))) {
        bytes32 subnode = keccak256(abi.encodePacked(node, label));

        // check that the parent has the CAN_REPLACE_SUBDOMAIN fuse burned, and the current domain has the CAN_UNWRAP fuse burned

        // stop gap for now before figuring out how to wrap root and eth nodes
        require(
            !canReplaceSubdomain(node) || node == ETH_NODE || node == ROOT_NODE,
            "Parent has not burned CAN_REPLACE_SUBDOMAIN fuse"
        );

        fuses[subnode] = fuses[subnode] | _fuses;

        require(!canUnwrap(subnode), "Domain has not burned unwrap fuse");
    }

    function setRecord(
        bytes32 node,
        address owner,
        address resolver,
        uint64 ttl
    ) external {
        //TODO add canTransfer when fuse is written
        require(canSetData(node), "Fuse is blown for setting data");
        ens.setRecord(node, owner, resolver, ttl);
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
        address newOwner
    ) public override ownerOnly(node) returns (bytes32) {
        bytes32 subnode = keccak256(abi.encodePacked(node, label));
        address owner = ens.owner(subnode);
        require(
            (owner == address(0) && canCreateSubdomain(node)) ||
                (owner != address(0) && canReplaceSubdomain(node)),
            "The fuse has been burned for creating or replacing a subdomain"
        );

        ens.setSubnodeOwner(node, label, newOwner);
    }

    function setSubnodeOwnerAndWrap(
        bytes32 node,
        bytes32 label,
        address newOwner,
        uint256 _fuses
    ) public override returns (bytes32) {
        setSubnodeOwner(node, label, newOwner);
        wrap(node, label, _fuses, newOwner);
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
        require(canSetData(node), "Fuse already blown for setting resolver");
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
        require(canSetData(node), "Fuse already blown for setting TTL");
        ens.setTTL(node, ttl);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) public override returns (bytes4) {
        //check if it's the eth registrar ERC721
        require(
            // Check erc721 .eth ownership is this contract
            registrar.ownerOf(tokenId) == address(this),
            "Wrapper only supports .eth ERC721 token transfers"
        );
        wrapETH2LD(bytes32(tokenId), 255, from);
        //if it is, wrap it, if it's not revert
        return _ERC721_RECEIVED;
    }
}

// 1. ETHRegistrarController.commit()
// 2. ETHRegistrarController.registerWithConfig()
// 3. SubdomainRegistrar.configure()

// a. ENS.setApprovalForAll(SubdomainRegistrar, true)
// b. RestrictiveWrapper.setApprovaForAll(SubdomainRegistrar, true)

// Nick's feedback

// minting takes 120k more gas. Check for another ERC721 contract that is lighter weight.

// When checking canUnwrap - need to ch
// When calling

// Options for wrapping. Approve Wrapper + wrap. Use ERC721 onERC721Received hook and add calldata to wrap it (safeTransferFrom)
// Do both safety
// Write the wrapped function
// Send ETH Registrar token to ourselves, so we have control over it (burn). Identify if node is .eth

//Combine CAN_SET_RESOLVER and CAN_SET_TTL to one fuse
// Add events so subgraph can track
