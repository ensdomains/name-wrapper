pragma solidity >=0.6.0 <0.8.0;
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./Resolver.sol";

abstract contract IRestrictedNameWrapper is IERC721 {
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

    function unwrap(bytes32 node, address owner) public virtual;

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

    function isOwnerOrApproved(bytes32 node, address addr)
        public
        virtual
        returns (bool);

    function setResolver(bytes32 node, address resolver) public virtual;

    function setOwner(bytes32 node, address owner) public virtual;

    uint256 public constant CAN_UNWRAP = 1;
    uint256 public constant CAN_SET_DATA = 2;
    uint256 public constant CAN_CREATE_SUBDOMAIN = 4;
    uint256 public constant CAN_REPLACE_SUBDOMAIN = 8;
    uint256 public constant CAN_DO_EVERYTHING = 0xfff; // set to 64 f's
}
