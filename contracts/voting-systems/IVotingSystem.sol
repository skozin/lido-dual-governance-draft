// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;


interface IVotingSystem {
    function submitProposal(bytes calldata data, address submitter) external returns (uint256 id, uint256 decidedAt);

    function getProposalExecData(
        uint256 id,
        bytes calldata data
    ) external view returns (
        address target,
        bytes memory execData
    );

    function isValidExecutionForwarder(address addr) external view returns (bool);
}
