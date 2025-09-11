/// @dev Minimal Chainlink AggregatorV3 mock
contract MockAggregatorV3 {
    uint8 public decimals_;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 _decimals) {
        decimals_ = _decimals;
        roundId = 1;
        answeredInRound = 1;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
        roundId += 1;
        answeredInRound = roundId;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 _roundId,
            int256 _answer,
            uint256 _startedAt,
            uint256 _updatedAt,
            uint80 _answeredInRound
        )
    {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}
