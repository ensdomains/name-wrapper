contract ProxyRegistry {
    mapping(address => address) public proxies;
}

contract ProxyRegistryWhitelist {
    ProxyRegistry public proxyRegistry;

    constructor(address proxyRegistryAddress) {
        proxyRegistry = ProxyRegistry(proxyRegistryAddress);
    }

    function isProxyForOwner(address owner, address caller)
        internal
        view
        returns (bool)
    {
        if (address(proxyRegistry) == address(0)) {
            return false;
        }
        return proxyRegistry.proxies(owner) == caller;
    }
}
