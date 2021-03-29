pragma solidity >=0.6.0 <0.8.0;
//import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155MetadataURI.sol";
import "./Resolver.sol";

abstract contract INFTFuseWrapper is IERC1155, IERC1155MetadataURI {
    function ownerOf(uint256 id) public virtual returns (address);

    function getData(uint256 tokenId)
        public
        virtual
        returns (address owner, uint96 fuses);

    function wrapETH2LD(
        bytes32 label,
        uint256 _fuses,
        address wrappedOwner
    ) public virtual;

    function wrap(
        bytes32 node,
        bytes32 label,
        uint256 _fuses,
        address wrappedOwner
    ) public virtual;

    function unwrap(
        bytes32 parentNode,
        bytes32 labelhash,
        address owner
    ) public virtual;

    function setSubnodeRecordAndWrap(
        bytes32 node,
        bytes32 label,
        address owner,
        address resolver,
        uint64 ttl,
        uint256 _fuses
    ) public virtual returns (bytes32);

    function setSubnodeOwner(
        bytes32 node,
        bytes32 label,
        address owner
    ) public virtual returns (bytes32);

    function setSubnodeOwnerAndWrap(
        bytes32 node,
        bytes32 label,
        address newOwner,
        uint256 _fuses
    ) public virtual returns (bytes32);

    function isOwnerOrApproved(bytes32 node, address addr)
        public
        virtual
        returns (bool);

    function setResolver(bytes32 node, address resolver) public virtual;

    function setOwner(bytes32 node, address owner) public virtual;

    uint256 public constant CANNOT_UNWRAP = 1;
    uint256 public constant CANNOT_TRANSFER = 2; // for DNSSEC names
    uint256 public constant CANNOT_SET_DATA = 4;
    uint256 public constant CANNOT_CREATE_SUBDOMAIN = 8;
    uint256 public constant CANNOT_REPLACE_SUBDOMAIN = 16;
    uint256 public constant CAN_DO_EVERYTHING = 0;
    uint256 public constant MINIMUM_PARENT_FUSES =
        CANNOT_UNWRAP | CANNOT_REPLACE_SUBDOMAIN;
}
