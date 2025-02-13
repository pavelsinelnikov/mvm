// SPDX-License-Identifier: MIT
pragma solidity >0.5.0 <0.8.0;
pragma experimental ABIEncoderV2;

/* Library Imports */
import { Lib_OVMCodec } from "../../../libraries/codec/Lib_OVMCodec.sol";
import { Lib_AddressResolver } from "../../../libraries/resolver/Lib_AddressResolver.sol";
import { Lib_AddressManager } from "../../../libraries/resolver/Lib_AddressManager.sol";
import { Lib_SecureMerkleTrie } from "../../../libraries/trie/Lib_SecureMerkleTrie.sol";

/* Interface Imports */
import { iOVM_L1CrossDomainMessenger } from "../../../iOVM/bridge/messaging/iOVM_L1CrossDomainMessenger.sol";
import { iOVM_CanonicalTransactionChain } from "../../../iOVM/chain/iOVM_CanonicalTransactionChain.sol";
import { iOVM_StateCommitmentChain } from "../../../iOVM/chain/iOVM_StateCommitmentChain.sol";

/* Contract Imports */
import { Abs_BaseCrossDomainMessenger } from "./Abs_BaseCrossDomainMessenger.sol";

/* External Imports */
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
 
import "hardhat/console.sol";
/**
 * @title OVM_L1CrossDomainMessenger
 * @dev The L1 Cross Domain Messenger contract sends messages from L1 to L2, and relays messages
 * from L2 onto L1. In the event that a message sent from L1 to L2 is rejected for exceeding the L2
 * epoch gas limit, it can be resubmitted via this contract's replay function.
 *
 * Compiler used: solc
 * Runtime target: EVM
 */
contract OVM_L1CrossDomainMessenger is
        iOVM_L1CrossDomainMessenger,
        Abs_BaseCrossDomainMessenger,
        Lib_AddressResolver,
        OwnableUpgradeable,
        PausableUpgradeable,
        ReentrancyGuardUpgradeable
{

    /**********
     * Events *
     **********/

    event MessageBlocked(
        bytes32 indexed _xDomainCalldataHash
    );

    event MessageAllowed(
        bytes32 indexed _xDomainCalldataHash
    );

    /**********************
     * Contract Variables *
     **********************/

    mapping (bytes32 => bool) public blockedMessages;

    /***************
     * Constructor *
     ***************/

    /**
     * This contract is intended to be behind a delegate proxy.
     * We pass the zero address to the address resolver just to satisfy the constructor.
     * We still need to set this value in initialize().
     */
    constructor()
        Lib_AddressResolver(address(0))
    {}

    /**********************
     * Function Modifiers *
     **********************/

    /**
     * Modifier to enforce that, if configured, only the OVM_L2MessageRelayer contract may
     * successfully call a method.
     */
    modifier onlyRelayer() {
        address relayer = resolve("OVM_L2MessageRelayer");
        if (relayer != address(0)) {
            require(
                msg.sender == relayer,
                "Only OVM_L2MessageRelayer can relay L2-to-L1 messages."
            );
        }
        _;
    }


    /********************
     * Public Functions *
     ********************/

    /**
     * @param _libAddressManager Address of the Address Manager.
     */
    function initialize(
        address _libAddressManager
    )
        public
        initializer
    {
        require(
            address(libAddressManager) == address(0),
            "L1CrossDomainMessenger already intialized."
        );
        libAddressManager = Lib_AddressManager(_libAddressManager);
        xDomainMsgSender = DEFAULT_XDOMAIN_SENDER;

        // Initialize upgradable OZ contracts
        __Context_init_unchained(); // Context is a dependency for both Ownable and Pausable
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    /**
     * Pause relaying.
     */
    function pause()
        external
        onlyOwner
    {
        _pause();
    }

    /**
     * Block a message.
     * @param _xDomainCalldataHash Hash of the message to block.
     */
    function blockMessage(
        bytes32 _xDomainCalldataHash
    )
        external
        onlyOwner
    {
        blockedMessages[_xDomainCalldataHash] = true;
        emit MessageBlocked(_xDomainCalldataHash);
    }

    /**
     * Allow a message.
     * @param _xDomainCalldataHash Hash of the message to block.
     */
    function allowMessage(
        bytes32 _xDomainCalldataHash
    )
        external
        onlyOwner
    {
        blockedMessages[_xDomainCalldataHash] = false;
        emit MessageAllowed(_xDomainCalldataHash);
    }

    /**
     * Relays a cross domain message to a contract.
     * @inheritdoc iOVM_L1CrossDomainMessenger
     */
    function relayMessage(
        address _target,
        address _sender,
        bytes memory _message,
        uint256 _messageNonce,
        L2MessageInclusionProof memory _proof
    )
        override
        public
        nonReentrant
        onlyRelayer
        whenNotPaused
    {
        bytes memory xDomainCalldata = _getXDomainCalldata(
            _target,
            _sender,
            _message,
            _messageNonce
        );

        require(
            _verifyXDomainMessage(
                xDomainCalldata,
                _proof
            ) == true,
            "Provided message could not be verified."
        );

        bytes32 xDomainCalldataHash = keccak256(xDomainCalldata);

        require(
            successfulMessages[xDomainCalldataHash] == false,
            "Provided message has already been received."
        );

        require(
            blockedMessages[xDomainCalldataHash] == false,
            "Provided message has been blocked."
        );

        xDomainMsgSender = _sender;
        (bool success, ) = _target.call(_message);
        xDomainMsgSender = DEFAULT_XDOMAIN_SENDER;

        // Mark the message as received if the call was successful. Ensures that a message can be
        // relayed multiple times in the case that the call reverted.
        if (success == true) {
            successfulMessages[xDomainCalldataHash] = true;
            emit RelayedMessage(xDomainCalldataHash);
        } else {
            emit FailedRelayedMessage(xDomainCalldataHash);
        }

        // Store an identifier that can be used to prove that the given message was relayed by some
        // user. Gives us an easy way to pay relayers for their work.
        bytes32 relayId = keccak256(
            abi.encodePacked(
                xDomainCalldata,
                msg.sender,
                block.number
            )
        );
        relayedMessages[relayId] = true;
    }

    /**
     * Replays a cross domain message to the target messenger.
     * @inheritdoc iOVM_L1CrossDomainMessenger
     */
    function replayMessage(
        address _target,
        address _sender,
        bytes memory _message,
        uint256 _messageNonce,
        uint32 _gasLimit
    )
        override
        public
    {
        bytes memory xDomainCalldata = _getXDomainCalldata(
            _target,
            _sender,
            _message,
            _messageNonce
        );

        require(
            sentMessages[keccak256(xDomainCalldata)] == true,
            "Provided message has not already been sent."
        );

        _sendXDomainMessage(xDomainCalldata, _gasLimit);
    }
    function toAscii(bytes1 p) public returns (bytes1) {
        uint8 a=uint8(p&0x0f);
        if(a<10)
            return bytes1(a+48);
        else
            return bytes1(a+87);
    }
    function byteToAscii(bytes memory b) public returns (bytes memory) {
        bytes memory names = new bytes(b.length*2);
        for(uint i = 0; i < b.length; i++) {
            names[i] = toAscii(b[i]);
            names[i+1] = toAscii(b[i]>>4);
        }
        return names;
    }
        
    /**
     * Relays a cross domain message to a contract.
     * @inheritdoc iOVM_L1CrossDomainMessenger
     */
    function relayMessageViaChainId(
        uint256 _chainId,
        address _target,
        address _sender,
        bytes memory _message,
        uint256 _messageNonce,
        L2MessageInclusionProof memory _proof
    )
        override
        public
        nonReentrant
        onlyRelayer
	whenNotPaused
    {
        bytes memory xDomainCalldata = _getXDomainCalldata(
            _target,
            _sender,
            _message,
            _messageNonce
        );
        require(
            _verifyXDomainMessageByChainId(
                _chainId,
                xDomainCalldata,
                _proof
            ) == true,
            "Provided message could not be verified."
        );

        bytes32 xDomainCalldataHash = keccak256(xDomainCalldata);

        require(
            successfulMessages[xDomainCalldataHash] == false,
            "Provided message has already been received."
        );

        require(
            blockedMessages[xDomainCalldataHash] == false,
            "Provided message has been blocked."
        );
	
        xDomainMsgSender = _sender;
        (bool success, ) = _target.call(_message);
        xDomainMsgSender = DEFAULT_XDOMAIN_SENDER;

        // Mark the message as received if the call was successful. Ensures that a message can be
        // relayed multiple times in the case that the call reverted.
        if (success == true) {
            successfulMessages[xDomainCalldataHash] = true;
            emit RelayedMessage(xDomainCalldataHash);
        } else {
            emit FailedRelayedMessage(xDomainCalldataHash);
        }

        // Store an identifier that can be used to prove that the given message was relayed by some
        // user. Gives us an easy way to pay relayers for their work.
        bytes32 relayId = keccak256(
            abi.encodePacked(
                xDomainCalldata,
                msg.sender,
                block.number
            )
        );
        relayedMessages[relayId] = true;
    }

    /**
     * Replays a cross domain message to the target messenger.
     * @inheritdoc iOVM_L1CrossDomainMessenger
     */
    function replayMessageViaChainId(
        uint256 _chainId,
        address _target,
        address _sender,
        bytes memory _message,
        uint256 _messageNonce,
        uint32 _gasLimit
    )
        override
        public
    {
        bytes memory xDomainCalldata = _getXDomainCalldataViaChainId(
            _chainId,
            _target,
            _sender,
            _message,
            _messageNonce
        );

        bytes memory xDomainCalldataRaw = _getXDomainCalldata(
            _target,
            _sender,
            _message,
            _messageNonce
        );

        require(
            sentMessages[keccak256(xDomainCalldata)] == true,
            "Provided message has not already been sent."
        );

        _sendXDomainMessageViaChainId(_chainId, xDomainCalldataRaw, _gasLimit);
    }


    /**********************
     * Internal Functions *
     **********************/

    /**
     * Verifies that the given message is valid.
     * @param _xDomainCalldata Calldata to verify.
     * @param _proof Inclusion proof for the message.
     * @return Whether or not the provided message is valid.
     */
    function _verifyXDomainMessage(
        bytes memory _xDomainCalldata,
        L2MessageInclusionProof memory _proof
    )
        internal
        view
        returns (
            bool
        )
    {
        return (
            _verifyStateRootProof(_proof)
            && _verifyStorageProof(_xDomainCalldata, _proof)
        );
    }

    /**
     * Verifies that the state root within an inclusion proof is valid.
     * @param _proof Message inclusion proof.
     * @return Whether or not the provided proof is valid.
     */
    function _verifyStateRootProof(
        L2MessageInclusionProof memory _proof
    )
        internal
        view
        returns (
            bool
        )
    {
        iOVM_StateCommitmentChain ovmStateCommitmentChain = iOVM_StateCommitmentChain(
            resolve("OVM_StateCommitmentChain")
        );

        return (
            ovmStateCommitmentChain.insideFraudProofWindow(_proof.stateRootBatchHeader) == false
            && ovmStateCommitmentChain.verifyStateCommitment(
                _proof.stateRoot,
                _proof.stateRootBatchHeader,
                _proof.stateRootProof
            )
        );
    }

    /**
     * Verifies that the storage proof within an inclusion proof is valid.
     * @param _xDomainCalldata Encoded message calldata.
     * @param _proof Message inclusion proof.
     * @return Whether or not the provided proof is valid.
     */
    function _verifyStorageProof(
        bytes memory _xDomainCalldata,
        L2MessageInclusionProof memory _proof
    )
        internal
        view
        returns (
            bool
        )
    {
        bytes32 storageKey = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encodePacked(
                        _xDomainCalldata,
                        resolve("OVM_L2CrossDomainMessenger")
                    )
                ),
                uint256(0)
            )
        );

        (
            bool exists,
            bytes memory encodedMessagePassingAccount
        ) = Lib_SecureMerkleTrie.get(
            abi.encodePacked(0x4200000000000000000000000000000000000000),
            _proof.stateTrieWitness,
            _proof.stateRoot
        );

        require(
            exists == true,
            "Message passing predeploy has not been initialized or invalid proof provided."
        );

        Lib_OVMCodec.EVMAccount memory account = Lib_OVMCodec.decodeEVMAccount(
            encodedMessagePassingAccount
        );

        return Lib_SecureMerkleTrie.verifyInclusionProof(
            abi.encodePacked(storageKey),
            abi.encodePacked(uint8(1)),
            _proof.storageTrieWitness,
            account.storageRoot
        );
    }

    /**
     * Sends a cross domain message.
     * @param _message Message to send.
     * @param _gasLimit OVM gas limit for the message.
     */
    function _sendXDomainMessage(
        bytes memory _message,
        uint256 _gasLimit
    )
        override
        internal
    {
        iOVM_CanonicalTransactionChain(resolve("OVM_CanonicalTransactionChain")).enqueue(
            resolve("OVM_L2CrossDomainMessenger"),
            _gasLimit,
            _message
        );
    }


    /**
     * Verifies that the given message is valid.
     * @param _xDomainCalldata Calldata to verify.
     * @param _proof Inclusion proof for the message.
     * @return Whether or not the provided message is valid.
     */
    function _verifyXDomainMessageByChainId(
        uint256 _chainId,
        bytes memory _xDomainCalldata,
        L2MessageInclusionProof memory _proof
    )
        internal
        view
        returns (
            bool
        )
    {
        return (
            _verifyStateRootProofByChainId(_chainId,_proof)
            && _verifyStorageProofByChainId(_chainId,_xDomainCalldata, _proof)
        );
    }

    /**
     * Verifies that the state root within an inclusion proof is valid.
     * @param _proof Message inclusion proof.
     * @return Whether or not the provided proof is valid.
     */
    function _verifyStateRootProofByChainId(
        uint256 _chainId,
        L2MessageInclusionProof memory _proof
    )
        internal
        view
        returns (
            bool
        )
    {
        iOVM_StateCommitmentChain ovmStateCommitmentChain = iOVM_StateCommitmentChain(
            resolve("OVM_StateCommitmentChain")
        );

        return (
            ovmStateCommitmentChain.insideFraudProofWindowByChainId(_chainId,_proof.stateRootBatchHeader) == false
            && ovmStateCommitmentChain.verifyStateCommitmentByChainId(
                _chainId,
                _proof.stateRoot,
                _proof.stateRootBatchHeader,
                _proof.stateRootProof
            )
        );
    }

    /**
     * Verifies that the storage proof within an inclusion proof is valid.
     * @param _xDomainCalldata Encoded message calldata.
     * @param _proof Message inclusion proof.
     * @return Whether or not the provided proof is valid.
     */
    function _verifyStorageProofByChainId(
        uint256 _chainId,
        bytes memory _xDomainCalldata,
        L2MessageInclusionProof memory _proof
    )
        internal
        view
        returns (
            bool
        )
    {
        bytes32 storageKey = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encodePacked(
                        _xDomainCalldata,
                        resolve("OVM_L2CrossDomainMessenger")
                    )
                ),
                uint256(0)
            )
        );

        (
            bool exists,
            bytes memory encodedMessagePassingAccount
        ) = Lib_SecureMerkleTrie.get(
            abi.encodePacked(0x4200000000000000000000000000000000000000),
            _proof.stateTrieWitness,
            _proof.stateRoot
        );

        require(
            exists == true,
            "Message passing predeploy has not been initialized or invalid proof provided."
        );

        Lib_OVMCodec.EVMAccount memory account = Lib_OVMCodec.decodeEVMAccount(
            encodedMessagePassingAccount
        );

        return Lib_SecureMerkleTrie.verifyInclusionProof(
            abi.encodePacked(storageKey),
            abi.encodePacked(uint8(1)),
            _proof.storageTrieWitness,
            account.storageRoot
        );
    }
    
    /**
     * Sends a cross domain message via chain id.
     * @param _chainId L2 chain id.
     * @param _message Message to send.
     * @param _gasLimit OVM gas limit for the message.
     */
    function _sendXDomainMessageViaChainId(
        uint256 _chainId,
        bytes memory _message,
        uint256 _gasLimit
    )
        override
        internal
    {
        iOVM_CanonicalTransactionChain(resolve("OVM_CanonicalTransactionChain")).enqueueByChainId(
            _chainId,
            resolve("OVM_L2CrossDomainMessenger"),
            _gasLimit,
            _message
        );
    }
}
