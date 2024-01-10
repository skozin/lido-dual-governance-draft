// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Configuration} from "./Configuration.sol";
import {GovernanceState} from "./GovernanceState.sol";
import {Agent} from "./Agent.sol";
import {IVotingSystem} from "./voting-systems/IVotingSystem.sol";


contract ConfigProxy is TransparentUpgradeableProxy {
    function proxyAdmin() external view returns (address) {
        return _proxyAdmin();
    }
}


contract DualGovernance {
    using SafeCast for uint256;

    event NewProposal(uint256 indexed votingSystemId, uint256 indexed id);
    event GovernanceReplaced(address governance);
    event ConfigSet(address config);
    event VotingSystemRegistered(address indexed facade, uint256 indexed id);
    event VotingSystemUnregistered(address indexed facade, uint256 indexed id);

    error ProposalSubmissionNotAllowed();
    error InvalidVotingSystem();
    error VotingSystemAlreadyRegistered();
    error InvalidProposalId();
    error UnknownProposalId();
    error ProposalIsNotExecutable();
    error ProposalAlreadyExecuted();
    error CannotCallOutsideExecution();
    error NestedExecutionProhibited();
    error NestedForwardingProhibited();
    error Unauthorized();

    struct Proposal {
        uint64 id;
        uint16 votingSystemId;
        uint64 submittedAt;
        uint64 decidedAt;
        bool isExecuted;
    }

    struct ProposalExecutionContext {
        bool isExecuting;
        bool isForwarding;
        uint16 votingSystemId;
        uint64 proposalId;
    }

    Configuration internal immutable CONFIG;
    Agent internal immutable AGENT;
    GovernanceState internal immutable GOV_STATE;

    mapping(uint256 => address) internal _votingSystems;
    uint256[] internal _votingSystemIds;
    uint256 internal _lastVotingSystemId;

    mapping(uint256 => Proposal) internal _proposals;
    ProposalExecutionContext internal _propExecution;


    constructor(address initialConfig, address escrowImpl) {
        CONFIG = Configuration(new ConfigProxy(initialConfig, address(this), new bytes(0)));
        AGENT = new Agent(address(this));
        GOV_STATE = new GovernanceState(CONFIG, address(this), escrowImpl);
        emit ConfigSet(initialConfig);
    }

    function replaceDualGovernance(address newGovernance) external {
        _assertExecutionByAdminVotingSystem(msg.sender);
        AGENT.setGovernance(newGovernance);
        emit GovernanceReplaced(newGovernance);
    }

    function updateConfig(address newConfig) external {
        _assertExecutionByAdminVotingSystem(msg.sender);
        ProxyAdmin admin = ProxyAdmin(ConfigProxy(CONFIG).proxyAdmin());
        admin.upgradeAndCall(CONFIG, newConfig, new bytes(0));
        emit ConfigSet(newConfig);
    }

    function hasVotingSystem(uint256 id) external view returns (bool) {
        return _votingSystems[id] != address(0);
    }

    function getVotingSystem(uint256 id) external view returns (IVotingSystem) {
        return _getVotingSystem(id);
    }

    function getVotingSystemIds() external view returns (uint256[] memory) {
        return _votingSystemIds;
    }

    function registerVotingSystem(address votingSystemFacade) external returns (uint256 id) {
        _assertExecutionByAdminVotingSystem(msg.sender);

        uint256 totalVotingSystems = _votingSystemIds.length;
        for (uint256 i = 0; i < totalVotingSystems; ++i) {
            uint256 id = _votingSystemIds[i];
            if (_votingSystems[id] == votingSystemFacade) {
                revert VotingSystemAlreadyRegistered();
            }
        }

        uint256 votingSystemId = ++_lastVotingSystemId;
        assert(_votingSystems[votingSystemId] == address(0));

        _votingSystems[votingSystemId] = votingSystemFacade;
        _votingSystemIds.push(votingSystemId);

        emit VotingSystemRegistered(votingSystemFacade, votingSystemId);
    }

    function unregisterVotingSystem(uint256 votingSystemId) external {
        _assertExecutionByAdminVotingSystem(msg.sender);

        address votingSystemFacade = _votingSystems[votingSystemId];
        if (votingSystemFacade == address(0)) {
            revert InvalidVotingSystem();
        }

        _votingSystems[votingSystemId] = address(0);

        uint256 totalVotingSystems = _votingSystemIds.length;
        uint256 i = 0;

        for (; i < totalVotingSystems; ++i) {
            if (_votingSystemIds[i] == votingSystemId) {
                break;
            }
        }
        for (++i; i < totalVotingSystems; ++i) {
            _votingSystemIds[i - 1] = _votingSystemIds[i];
        }

        emit VotingSystemUnregistered(votingSystemFacade, votingSystemId);
    }

    function killAllPendingProposals() external {
        IVotingSystem votingSystem = _getVotingSystem(CONFIG.adminVotingSystemId());
        if (!votingSystem.isValidExecutionForwarder(msg.sender)) {
            revert Unauthorized();
        }
        GOV_STATE.killAllPendingProposals();
    }

    function getProposal(uint256 votingSystemId, uint256 proposalId) external view returns (Proposal memory) {
        return _loadProposal(_getProposalKey(votingSystemId, proposalId));
    }

    function submitProposal(uint256 votingSystemId, bytes calldata data) external returns (uint256 id) {
        if (!GOV_STATE.isProposalSubmissionAllowed()) {
            revert ProposalSubmissionNotAllowed();
        }
        IVotingSystem votingSystem = _getVotingSystem(votingSystemId);
        (uint256 proposalId, uint256 decidedAt) = votingSystem.submitProposal(data, msg.sender);
        _saveProposal(_getProposalKey(votingSystemId, proposalId), Proposal({
            id: proposalId.toUint64(),
            votingSystemId: votingSystemId.toUint16(),
            submittedAt: _getTime().toUint64(),
            decidedAt: decidedAt.toUint64(),
            isExecuted: false,
        }));
    }

    function executeProposal(uint256 votingSystemId, uint256 proposalId) external {
        if (_propExecution.isExecuting) {
            revert NestedExecutionProhibited();
        }
        IVotingSystem votingSystem = _getVotingSystem(votingSystemId);
        uint256 proposalKey = _getProposalKey(votingSystemId, proposalId);
        Proposal memory proposal = _loadProposal(proposalKey);
        if (proposal.isExecuted) {
            revert ProposalAlreadyExecuted();
        }
        if (!GOV_STATE.isProposalExecutable(proposal.submittedAt, proposal.decidedAt)) {
            revert ProposalIsNotExecutable();
        }
        _propExecution = ProposalExecutionContext({
            isExecuting: true,
            isForwarding: false,
            votingSystemId: votingSystemId.toUint16(),
            proposalId: proposalId.toUint64(),
        });
        proposal.isExecuted = true;
        _saveProposal(proposalKey, proposal);
        (address target, bytes memory data) = votingSystem.getProposalExecData(proposalId);
        AGENT.forwardCall(target, data);
        assert(!_propExecution.isForwarding);
        _propExecution.isExecuting = false;
    }

    function forwardCall(address target, bytes calldata data) external {
        ProposalExecutionContext memory execution = _propExecution;
        _assertValidCallerForExecution(execution, msg.sender);
        if (execution.isForwarding) {
            revert NestedForwardingProhibited();
        }
        _propExecution.isForwarding = true;
        AGENT.forwardCall(target, data);
        _propExecution.isForwarding = false;
    }

    function _assertExecutionByAdminVotingSystem(address caller) internal {
        ProposalExecutionContext memory execution = _propExecution;
        _assertValidCallerForExecution(execution, caller);
        if (execution.votingSystemId != CONFIG.adminVotingSystemId()) {
            revert Unauthorized();
        }
    }

    function _assertValidCallerForExecution(ProposalExecutionContext memory execution, address caller) internal {
        if (!execution.isExecuting) {
            revert CannotCallOutsideExecution();
        }
        IVotingSystem votingSystem = _getVotingSystem(execution.votingSystemId);
        if (!votingSystem.isValidExecutionForwarder(caller)) {
            revert Unauthorized();
        }
    }

    function _getVotingSystem(uint256 id) internal returns (IVotingSystem) {
        address votingSystem = _votingSystems[id];
        if (votingSystem == address(0)) {
            revert InvalidVotingSystem();
        }
        return IVotingSystem(votingSystem);
    }

    function _loadProposal(uint256 proposalKey) internal view returns (Proposal memory) {
        Proposal memory proposal = _proposals[proposalKey];
        if (proposal.submittedAt == 0) {
            revert UnknownProposalId();
        }
        return proposal;
    }

    function _saveProposal(uint256 proposalKey, Proposal memory proposal) internal {
        _proposals[proposalKey] = proposal;
    }

    function _getProposalKey(uint256 votingSystemId, uint256 proposalId) internal pure returns (uint256) {
        if (votingSystemId > type(uint16).max) {
            revert InvalidVotingSystem();
        }
        if (proposalId > type(uint64).max) {
            revert InvalidProposalId();
        }
        return (votingSystemId << 64) | proposalId;
    }

    function _getTime() internal vitrual view returns (uint256) {
        return block.timestamp;
    }
}