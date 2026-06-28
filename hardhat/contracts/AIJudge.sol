// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

contract AIJudge is PrecompileConsumer {

    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2000;

    uint256 public nextBountyId = 1;

    enum BountyStatus { Open, Judging, Finalized }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        BountyStatus status;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 submissionCount;
    }

    struct Submission {
        address submitter;
        bytes32 commitment;
        string answer;
        bool revealed;
    }

    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => mapping(uint256 => Submission)) public submissions;
    mapping(uint256 => mapping(address => uint256)) public participantIndex;
    mapping(uint256 => mapping(address => bool)) public hasSubmitted;

    event BountyCreated(uint256 indexed bountyId, address indexed owner, uint256 reward);
    event CommitmentSubmitted(uint256 indexed bountyId, uint256 indexed index, address indexed participant);
    event AnswerRevealed(uint256 indexed bountyId, uint256 indexed index, address indexed participant);
    event BountyJudged(uint256 indexed bountyId);
    event WinnerFinalized(uint256 indexed bountyId, uint256 winnerIndex, address winner);

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "Not bounty owner");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "Reward required");
        require(submissionDeadline > block.timestamp, "Invalid submission deadline");
        require(revealDeadline > submissionDeadline, "Invalid reveal deadline");

        bountyId = nextBountyId++;

        bounties[bountyId] = Bounty({
            owner: msg.sender,
            title: title,
            rubric: rubric,
            reward: msg.value,
            submissionDeadline: submissionDeadline,
            revealDeadline: revealDeadline,
            status: BountyStatus.Open,
            aiReview: "",
            winnerIndex: type(uint256).max,
            submissionCount: 0
        });

        emit BountyCreated(bountyId, msg.sender, msg.value);
    }

    function submitCommitment(uint256 bountyId, bytes32 commitment) external {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp < bounty.submissionDeadline, "Submission closed");
        require(!hasSubmitted[bountyId][msg.sender], "Already submitted");
        require(bounty.submissionCount < MAX_SUBMISSIONS, "Max submissions reached");

        uint256 index = bounty.submissionCount;

        submissions[bountyId][index] = Submission({
            submitter: msg.sender,
            commitment: commitment,
            answer: "",
            revealed: false
        });

        participantIndex[bountyId][msg.sender] = index;
        hasSubmitted[bountyId][msg.sender] = true;
        bounty.submissionCount++;

        emit CommitmentSubmitted(bountyId, index, msg.sender);
    }

    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp > bounty.submissionDeadline, "Reveal not started");
        require(block.timestamp < bounty.revealDeadline, "Reveal closed");
        require(hasSubmitted[bountyId][msg.sender], "No commitment");

        uint256 index = participantIndex[bountyId][msg.sender];
        Submission storage sub = submissions[bountyId][index];
        require(!sub.revealed, "Already revealed");

        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        require(expected == sub.commitment, "Invalid reveal");

        sub.answer = answer;
        sub.revealed = true;

        emit AnswerRevealed(bountyId, index, msg.sender);
    }

    function judgeBounty(uint256 bountyId, bytes calldata llmInput) external onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(block.timestamp > bounty.revealDeadline, "Reveal not finished");
        require(bounty.status == BountyStatus.Open, "Invalid status");

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);
        (bool hasError, bytes memory result, , string memory err, ) = 
            abi.decode(output, (bool, bytes, bytes, string, bytes));
        require(!hasError, err);

        bounty.status = BountyStatus.Judging;
        bounty.aiReview = result;

        emit BountyJudged(bountyId);
    }

    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];
        require(bounty.status == BountyStatus.Judging, "Not judged yet");
        require(winnerIndex < bounty.submissionCount, "Invalid index");
        require(submissions[bountyId][winnerIndex].revealed, "Winner not revealed");

        bounty.status = BountyStatus.Finalized;
        bounty.winnerIndex = winnerIndex;

        address winner = submissions[bountyId][winnerIndex].submitter;
        uint256 amount = bounty.reward;
        bounty.reward = 0;

        (bool success, ) = payable(winner).call{value: amount}("");
        require(success, "Transfer failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner);
    }

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return bounties[bountyId];
    }

    function getSubmission(uint256 bountyId, uint256 index) external view returns (Submission memory) {
        return submissions[bountyId][index];
    }
}
