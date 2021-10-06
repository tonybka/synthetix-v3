//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@synthetixio/core-contracts/contracts/proxy/ForwardingProxy.sol";
import "./storage/ProxyNamespace.sol";

contract Proxy is ForwardingProxy, ProxyNamespace {
    // solhint-disable-next-line no-empty-blocks
    constructor(address firstImplementation) ForwardingProxy(firstImplementation) {}

    function _setImplementation(address newImplementation) internal override {
        _proxyStorage().implementation = newImplementation;
    }

    function _getImplementation() internal view override returns (address) {
        return _proxyStorage().implementation;
    }
}