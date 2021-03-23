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

        //burn all fuses for ROOT_NODE and ETH_NODE

        fuses[ETH_NODE] = 255;
        fuses[ROOT_NODE] = 255;
    }

    function makeNode(bytes32 node, bytes32 label)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(node, label));
    }

    modifier ownerOnly(bytes32 node) {
        require(
            isOwnerOrApproved(node, msg.sender),
            "msg.sender is not the owner or approved"
        );
        _;
    }

    function isOwnerOrApproved(bytes32 node, address addr)
        public
        view
        override
        returns (bool)
    {
        return
            ownerOf(uint256(node)) == addr ||
            isApprovedForAll(ownerOf(uint256(node)), addr);
    }

    function canUnwrap(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_UNWRAP == 0;
    }

    function canTransfer(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_TRANSFER == 0;
    }

    function canSetData(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_SET_DATA == 0;
    }

    function canCreateSubdomain(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_CREATE_SUBDOMAIN == 0;
    }

    function canReplaceSubdomain(bytes32 node) public view returns (bool) {
        return fuses[node] & CANNOT_REPLACE_SUBDOMAIN == 0;
    }

    function canCreateOrReplaceSubdomain(bytes32 node, bytes32 label)
        public
        returns (bool)
    {
        bytes32 subnode = makeNode(node, label);
        address owner = ens.owner(subnode);

        return
            (owner == address(0) && canCreateSubdomain(node)) ||
            (owner != address(0) && canReplaceSubdomain(node));
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
        bytes32 node = makeNode(ETH_NODE, label);

        //set fuses
        fuses[node] = _fuses;

        // .eth registar uses the labelhash of the node
        uint256 tokenId = uint256(label);

        //check msg.sender() == authorised or ens.owner

        // transfer the token from the user to this contract
        address currentOwner = registrar.ownerOf(tokenId);
        registrar.transferFrom(currentOwner, address(this), tokenId);

        // transfer the ens record back to the new owner (this contract)
        registrar.reclaim(tokenId, address(this));

        // mint a new ERC721 token
        mintERC721(uint256(node), wrappedOwner, "");
    }

    function wrap(
        bytes32 parentNode,
        bytes32 label,
        uint256 _fuses,
        address wrappedOwner
    ) public override {
        //check if the parent is !canReplaceSubdomain(node) if is, do the fuse, else, all not burned

        require(
            parentNode != ETH_NODE,
            ".eth domains need to use the wrapETH2LD"
        );

        bytes32 node = makeNode(parentNode, label);

        // TODO: Check if parent cannot replace subdomains, then allow fuses, otherwise revert
        fuses[node] = _fuses;
        address owner = ens.owner(node);

        require(
            owner == msg.sender, /* TODO:  || add authorised by sender */
            "Domain is not owned by the sender"
        );
        ens.setOwner(node, address(this));
        mintERC721(uint256(node), wrappedOwner, ""); //TODO add URI
    }

    function unwrap(
        bytes32 parentNode,
        bytes32 label,
        address owner
    ) public override ownerOnly(makeNode(parentNode, label)) {
        // Check address is not 0x0
        require(owner != address(0x0));
        bytes32 node = makeNode(parentNode, label);
        // TODO: add support for unwrapping .eth
        require(canUnwrap(node), "Domain is unwrappable");

        fuses[node] = 0;
        _burn(uint256(node));
        ens.setOwner(node, owner);
    }

    //TODO: Add a decorator for ownerOnly with multiple arguments to check parent

    function burnFuses(
        bytes32 node,
        bytes32 label,
        uint256 _fuses
    ) public ownerOnly(makeNode(node, label)) {
        bytes32 subnode = makeNode(node, label);

        // check that the parent has the CAN_REPLACE_SUBDOMAIN fuse burned, and the current domain has the CAN_UNWRAP fuse burned

        require(
            !canReplaceSubdomain(node),
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
        require(
            canCreateOrReplaceSubdomain(node, label),
            "The fuse has been burned for creating or replacing a subdomain"
        );

        return ens.setSubnodeRecord(node, label, addr, resolver, ttl);
    }

    function setSubnodeOwner(
        bytes32 node,
        bytes32 label,
        address newOwner
    ) public override ownerOnly(node) returns (bytes32) {
        require(
            canCreateOrReplaceSubdomain(node, label),
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
        //TODO: replace with _wrap that doesn't transfer
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
        //TODO: replace with _wrap that doesn't transfer
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
        require(canTransfer(node), "Fuse already blown for setting owner");
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
        wrapETH2LD(bytes32(tokenId), 0, from);
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
