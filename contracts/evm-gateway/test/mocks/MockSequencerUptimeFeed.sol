
/// @dev Minimal Chainlink Sequencer Uptime Feed mock (status: 0=UP, 1=DOWN)
contract MockSequencerUptimeFeed {
    int256 public status;
    uint256 public updatedAt;
    uint80 public roundId;

    function setStatus(bool down, uint256 _updatedAt) external {
        status = down ? int256(1) : int256(0);
        updatedAt = _updatedAt;
        roundId += 1;
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 _roundId,
            int256 _status,
            uint256 _startedAt,
            uint256 _updatedAt,
            uint80 _answeredInRound
        )
    {
        return (roundId, status, 0, updatedAt, roundId);
    }
}