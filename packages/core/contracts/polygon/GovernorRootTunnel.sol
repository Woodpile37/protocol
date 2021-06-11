// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../external/polygon/tunnel/FxBaseRootTunnel.sol";

/**
 * @title Governance relayer contract to be deployed on Ethereum that receives messages from the owner (Governor) and
 * sends them to sidechain.
 */
contract GovernorRootTunnel is Ownable, FxBaseRootTunnel {
    event RelayedGovernanceRequest(address indexed to, uint256 value, bytes data);

    constructor(address _checkpointManager, address _fxRoot) FxBaseRootTunnel(_checkpointManager, _fxRoot) {}

    /**
     * @notice This should be called in order to relay a governance request to the `GovernorChildTunnel` contract
     * deployed to the sidechain. Note: this can only be called by the owner (presumably the Ethereum Governor
     * contract).
     */
    function relayGovernance(
        address to,
        uint256 value,
        bytes memory data
    ) external onlyOwner {
        _sendMessageToChild(abi.encode(to, value, data));
        emit RelayedGovernanceRequest(to, value, data);
    }

    /**
     * @notice Function called as callback from child tunnel. Should not do anything as governance actions should only
     * be sent from root to child.
     */
    function _processMessageFromChild(bytes memory data) internal override {
        // no-op
    }
}