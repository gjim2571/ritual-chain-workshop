// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "../hardhat/contracts/utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

contract PrivacyAIBountyJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet public wallet = IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Commitment {
        address submitter;
        bytes32 commitmentHash;
        bool revealed;
    }

    struct RevealedAnswer {
        string answer;
        bytes32 salt;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Commitment[] commitments;
        RevealedAnswer[] revealedAnswers;
    }

    mapping(uint256 => Bounty) public bounties;

    event BountyCreated(uint256 indexed bountyId, address indexed owner, string title, uint256 reward, uint256 submissionDeadline, uint256 revealDeadline);
    event CommitmentSubmitted(uint256 indexed bountyId, uint256 indexed index, address indexed submitter);
    event AnswerRevealed(uint256 indexed bountyId, uint256 indexed index, address indexed submitter);
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(uint256 indexed bountyId, uint256 indexed winnerIndex, address indexed winner, uint256 reward);

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "invalid submission deadline");
        require(revealDeadline > submissionDeadline, "reveal after submission");

        bountyId = nextBountyId++;
        Bounty storage b = bounties[bountyId];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.revealDeadline = revealDeadline;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submissionDeadline, revealDeadline);
    }

    function submitCommitment(uint256 bountyId, bytes32 commitment) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp < b.submissionDeadline, "submission closed");
        require(!b.judged && !b.finalized, "closed");

        for (uint i = 0; i < b.commitments.length; i++) {
            require(b.commitments[i].submitter != msg.sender, "already committed");
        }
        require(b.commitments.length < MAX_SUBMISSIONS, "max submissions");

        b.commitments.push(Commitment({submitter: msg.sender, commitmentHash: commitment, revealed: false}));
        emit CommitmentSubmitted(bountyId, b.commitments.length - 1, msg.sender);
    }

    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp >= b.submissionDeadline && block.timestamp < b.revealDeadline, "reveal window closed");

        uint256 idx = type(uint256).max;
        for (uint i = 0; i < b.commitments.length; i++) {
            if (b.commitments[i].submitter == msg.sender) {
                idx = i; break;
            }
        }
        require(idx != type(uint256).max, "no commitment");
        require(!b.commitments[idx].revealed, "already revealed");

        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        require(expected == b.commitments[idx].commitmentHash, "hash mismatch");

        b.commitments[idx].revealed = true;
        b.revealedAnswers.push(RevealedAnswer({answer: answer, salt: salt}));

        emit AnswerRevealed(bountyId, idx, msg.sender);
    }

    function judgeAll(uint256 bountyId, bytes calldata llmInput) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp >= b.revealDeadline, "reveal not finished");
        require(!b.judged, "already judged");

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);
        (bool hasError, bytes memory completionData, , string memory errMsg, ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));
        require(!hasError, errMsg);

        b.judged = true;
        b.aiReview = completionData;
        emit AllAnswersJudged(bountyId, completionData);
    }

    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(b.judged, "not judged");
        require(!b.finalized, "already finalized");
        require(winnerIndex < b.revealedAnswers.length, "invalid index");

        b.finalized = true;
        b.winnerIndex = winnerIndex;

        address winner = b.commitments[winnerIndex].submitter;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool success, ) = payable(winner).call{value: reward}("");
        require(success, "transfer failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function getBounty(uint256 bountyId) external view bountyExists(bountyId) returns (
        address owner,
        string memory title,
        string memory rubric,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline,
        bool judged,
        bool finalized,
        uint256 commitmentCount,
        uint256 winnerIndex,
        bytes memory aiReview
    ) {
        Bounty storage b = bounties[bountyId];
        return (
            b.owner, b.title, b.rubric, b.reward,
            b.submissionDeadline, b.revealDeadline,
            b.judged, b.finalized,
            b.commitments.length, b.winnerIndex, b.aiReview
        );
    }
}
