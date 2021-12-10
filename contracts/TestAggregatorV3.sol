//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

contract TestAggregatorV3 {
    function decimals() external view returns (uint8) {
        return 8;
    }
//  // getRoundData and latestRoundData should both raise "No data present"
//  // if they do not have data to report, instead of returning unset values
//  // which could be misinterpreted as actual reported values.
//   function getRoundData(
//     uint80 _roundId
//   )
//     external
//     view
//     returns (
//       uint80 roundId,
//       int256 answer,
//       uint256 startedAt,
//       uint256 updatedAt,
//       uint80 answeredInRound
//     );

  function latestRoundData() external view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) {
        return (0, 100_000_000, 0, 1, 0);
    }
}