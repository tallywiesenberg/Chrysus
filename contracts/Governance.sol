pragma solidity ^0.8.0;

import "contracts/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "contracts/interfaces/IChrysus.sol";
import "contracts/interfaces/ISwap.sol";
import "contracts/interfaces/IStabilityModule.sol";
import "contracts/interfaces/ILending.sol";

contract Governance is DSMath, ERC20 {
    IChrysus chrysus;
    ISwap swapSolution;
    IStabilityModule stabilityModule;
    ILending lending;

    address public team;

    uint256 public lastMintTimestamp;
    uint256 public voteCount;

    struct Vote {
        uint256 startTime;
        uint256 tallyTime;
        uint256 amountSupporting;
        uint256 amountAgainst;
        uint256 amountAbstained;
        bool executed;
        bool result;
        bytes4 voteFunction;
        address voteAddress;
        address initiator;
        bytes data;
        mapping(address => bool) voted;
    }

    mapping(uint256 => Vote) public voteInfo;

    modifier onlyVoter() {
        require(
            (stabilityModule.getGovernanceStake(msg.sender).startTime >
                block.timestamp - 90 days) ||
                (stabilityModule
                    .getGovernanceStake(msg.sender)
                    .lastGovContractCall > block.timestamp - 90 days),
            "stake is inactive, hasn't been used in 3 months"
        );

        require(
            stabilityModule.getGovernanceStake(msg.sender).startTime <
                block.timestamp - 30 days,
            "stake must be at least 30 days old!"
        );
        _;
    }

    constructor(address _team) ERC20("Chrysus Governance", "CGT") {
        _mint(_team, 72e25);

        team = _team;
    }

    function init(
        address _chrysus,
        address _swapSolution,
        address _lending
    ) external {
        require(msg.sender == team, "can only be initted by team");
        chrysus = IChrysus(_chrysus);
        swapSolution = ISwap(_swapSolution);
        lending = ILending(_lending);
    }

    function mintDaily() external {
        uint256 numDays = (block.timestamp - lastMintTimestamp) / 86400;

        //300,000 minted to CHC contract
        _mint(address(chrysus), 3e23 * numDays);

        //300,000 minted to CHC liquidity providers on swap solution
        _mint(address(swapSolution), 3e23 * numDays);

        //300,000 minted to borrowers and lenders on lending solution
        _mint(address(lending), 3e23 * numDays);

        //100,000 minted to a reserve
        _mint(address(this), 1e23 * numDays);
    }

    function proposeVote(
        address _contract,
        bytes4 _function,
        bytes memory _data
    ) external onlyVoter {
        require(
            stabilityModule.getGovernanceStake(msg.sender).amount >
                stabilityModule.getTotalPoolAmount() / 10,
            "user needs to stake more tokens in pool to start vote!"
        );

        voteCount++;
        uint256 voteId = voteCount;
        Vote storage _thisVote = voteInfo[voteId];
        _thisVote.initiator = msg.sender;
        _thisVote.startTime = block.timestamp;
        _thisVote.voteAddress = _contract;
        _thisVote.voteFunction = _function;
        _thisVote.data = _data;
    }

    function executeVote(uint256 _voteCount) external onlyVoter {
        //75 percent of pool needs to vote

        Vote storage v = voteInfo[_voteCount];

        require(
            v.amountSupporting + v.amountAgainst + v.amountAbstained >
                (stabilityModule.getTotalPoolAmount() * 3) / 4,
            "75% of pool has not voted yet!"
        );

        require(!v.executed, "Dispute has already been executed");
        require(v.tallyTime == 0, "Vote has already been tallied");
        require(_voteCount <= voteCount, "Vote does not exist");
        uint256 _duration = 2 days;
        require(
            block.timestamp - v.startTime > _duration,
            "Time for voting has not elapsed"
        );

        if (
            v.amountSupporting >
            (stabilityModule.getTotalPoolAmount() * 51) / 100
        ) {
            v.result = true;
            address _destination = v.voteAddress;
            bool _succ;
            bytes memory _res;
            (_succ, _res) = _destination.call(
                abi.encodePacked(v.voteFunction, v.data)
            ); //When testing _destination.call can require higher gas than the standard. Be sure to increase the gas if it fails.
        } else {
            v.result = false;
        }
    }

    function vote(
        uint256 _voteCount,
        bool _supports,
        bool _abstains
    ) external onlyVoter {
        require(_voteCount <= voteCount, "Vote does not exist");
        Vote storage v = voteInfo[_voteCount];
        require(v.tallyTime == 0, "Vote has already been tallied");
        require(!v.voted[msg.sender], "Sender has already voted");

        v.voted[msg.sender] = true;
        if (_abstains) {
            v.amountAbstained += balanceOf(msg.sender);
        } else if (_supports) {
            v.amountSupporting += balanceOf(msg.sender);
        } else {
            v.amountAgainst += balanceOf(msg.sender);
        }
    }
}
