pragma solidity ^0.5.11;

import {RLPReader} from "solidity-rlp/contracts/RLPReader.sol";
import {System} from "./System.sol";
import {IStateReceiver} from "./IStateReceiver.sol";

contract StateReceiver is System {
  using RLPReader for bytes;
  using RLPReader for RLPReader.RLPItem;

  uint256 public lastStateId;

  bytes32 public failedStateSyncsRoot;
  mapping(bytes32 => bool) public nullifier;

  mapping(uint256 => bytes) public failedStateSyncs;

  address public rootSetter;
  uint256 public constant TREE_DEPTH = 6;

  event StateCommitted(uint256 indexed stateId, bool success);
  event StateSyncReplay(uint256 indexed stateId);

  constructor(address _rootSetter) public {
    rootSetter = _rootSetter;
  }

  function commitState(uint256 syncTime, bytes calldata recordBytes) external onlySystem returns (bool success) {
    // parse state data
    RLPReader.RLPItem[] memory dataList = recordBytes.toRlpItem().toList();
    uint256 stateId = dataList[0].toUint();
    require(lastStateId + 1 == stateId, "StateIds are not sequential");
    lastStateId++;
    address receiver = dataList[1].toAddress();
    bytes memory stateData = dataList[2].toBytes();
    // notify state receiver contract, in a non-revert manner
    if (isContract(receiver)) {
      uint256 txGas = 5000000;

      bytes memory data = abi.encodeWithSignature("onStateReceive(uint256,bytes)", stateId, stateData);
      // solium-disable-next-line security/no-inline-assembly
      assembly {
        success := call(txGas, receiver, 0, add(data, 0x20), mload(data), 0, 0)
      }
      emit StateCommitted(stateId, success);
      if (!success) failedStateSyncs[stateId] = abi.encode(receiver, stateData);
    }
  }

  function replayFailedStateSync(uint256 stateId) external {
    bytes memory stateSyncData = failedStateSyncs[stateId];
    require(stateSyncData.length != 0, "!found");
    delete failedStateSyncs[stateId];

    (address receiver, bytes memory stateData) = abi.decode(stateSyncData, (address, bytes));
    emit StateSyncReplay(stateId);
    IStateReceiver(receiver).onStateReceive(stateId, stateData); // revertable
  }

  function setRoot(bytes32 _root) external {
    require(msg.sender == rootSetter, "!rootSetter");
    require(failedStateSyncsRoot == bytes32(0), "already set");
    failedStateSyncsRoot = _root;
  }

  function replayHistoricFailedStateSync(
    bytes32[TREE_DEPTH] calldata proof,
    uint256 proofIndex,
    uint256 stateId,
    address receiver,
    bytes calldata data
  ) external {
    bytes32 root = failedStateSyncsRoot;
    require(root != bytes32(0), "!root");

    bytes32 leafHash = keccak256(abi.encode(stateId, receiver, data));
    bytes32 zeroHash = keccak256(abi.encode(uint256(0), address(0), new bytes(0)));
    require(leafHash != zeroHash && !nullifier[leafHash], "used");
    nullifier[leafHash] = true;

    require(root == _getRoot(proof, proofIndex, leafHash), "!proof");

    emit StateSyncReplay(stateId);
    IStateReceiver(receiver).onStateReceive(stateId, data);
  }

  function _getRoot(bytes32[TREE_DEPTH] memory proof, uint256 index, bytes32 leafHash) private pure returns (bytes32) {
    bytes32 node = leafHash;

    for (uint256 height = 0; height < TREE_DEPTH; height++) {
      if (((index >> height) & 1) == 1) node = keccak256(abi.encodePacked(proof[height], node));
      else node = keccak256(abi.encodePacked(node, proof[height]));
    }

    return node;
  }

  // check if address is contract
  function isContract(address _addr) private view returns (bool) {
    uint32 size;
    // solium-disable-next-line security/no-inline-assembly
    assembly {
      size := extcodesize(_addr)
    }
    return (size > 0);
  }
}
