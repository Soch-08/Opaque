// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title ConfidentialCreditScore
 * @notice Onchain credit scoring using FHE — inputs stay encrypted, score is verifiable.
 * @dev Built for Zama Developer Program Mainnet Season 2 — Builder Track
 *
 * Architecture:
 *  - Users submit encrypted financial signals (wallet age, tx count, repayment ratio,
 *    collateral ratio, default count) via FHE ciphertexts.
 *  - The contract computes a weighted score entirely on encrypted values.
 *  - Only the final score (a single uint64) is decrypted via the DecryptionOracle.
 *  - Raw inputs are NEVER visible onchain — not to the contract owner, not to anyone.
 *  - Score tiers (Poor / Fair / Good / Excellent) are revealed, not raw numbers.
 */
contract ConfidentialCreditScore is SepoliaConfig {

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct CreditProfile {
        // Encrypted signals (stored as handles, never plaintext onchain)
        euint64 encWalletAgeDays;       // 0–3650 days  (10 years max)
        euint64 encTxCount;             // 0–10000 transactions
        euint64 encRepaymentRatioBps;   // 0–10000 bps  (0–100.00%)
        euint64 encCollateralRatioBps;  // 0–50000 bps  (0–500.00%)
        euint64 encDefaultCount;        // 0–255 defaults
        euint64 encComputedScore;       // Encrypted score 0–850

        // Public metadata (non-sensitive)
        uint256 lastUpdated;
        bool    decryptionPending;
        bool    hasScore;

        // Decrypted outputs (revealed after oracle callback)
        uint64  publicScore;            // 300–850 range (FICO-like)
        string  scoreTier;              // "Poor" / "Fair" / "Good" / "Excellent"
    }

    // ─── State ────────────────────────────────────────────────────────────────

    mapping(address => CreditProfile) private profiles;
    mapping(uint256 => address)       private requestToUser;  // requestId → user

    address public owner;
    uint256 public totalProfiles;
    uint256 public totalDecryptions;

    // Score tier thresholds (FICO-inspired, 300–850 range)
    uint64 public constant SCORE_MIN       = 300;
    uint64 public constant SCORE_POOR_MAX  = 579;
    uint64 public constant SCORE_FAIR_MAX  = 669;
    uint64 public constant SCORE_GOOD_MAX  = 739;
    // 740–850 = Excellent

    // Weights (sum = 100)
    // Payment history  35%, Utilization 30%, Age 15%, Mix/Tx 10%, Defaults -20 pts each
    uint64 public constant W_REPAYMENT   = 35;
    uint64 public constant W_COLLATERAL  = 30;
    uint64 public constant W_AGE         = 15;
    uint64 public constant W_TXCOUNT     = 10;
    uint64 public constant W_DEFAULT_PEN = 20; // penalty per default, applied after

    // ─── Events ───────────────────────────────────────────────────────────────

    event ProfileSubmitted(address indexed user, uint256 timestamp);
    event ScoreRequested(address indexed user, uint256 requestId);
    event ScoreRevealed(address indexed user, uint64 score, string tier);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        owner = msg.sender;
    }

    // ─── Core Functions ───────────────────────────────────────────────────────

    /**
     * @notice Submit encrypted financial signals to build a credit profile.
     * @dev All five inputs are ciphertexts encrypted client-side via the Relayer SDK.
     *      The attestation (inputProof) proves the ciphertexts were encrypted correctly
     *      for this specific contract call.
     *
     * @param encWalletAge       Encrypted wallet age in days
     * @param encTxCount         Encrypted lifetime transaction count
     * @param encRepaymentRatio  Encrypted repayment ratio (0–10000 bps)
     * @param encCollateralRatio Encrypted collateral ratio (0–50000 bps)
     * @param encDefaultCount    Encrypted number of defaults/liquidations
     * @param inputProof         Attestation proving ciphertext validity
     */
    function submitProfile(
        externalEuint64 encWalletAge,
        externalEuint64 encTxCount,
        externalEuint64 encRepaymentRatio,
        externalEuint64 encCollateralRatio,
        externalEuint64 encDefaultCount,
        bytes calldata   inputProof
    ) external {
        CreditProfile storage p = profiles[msg.sender];

        // Deserialise encrypted inputs and verify attestation
        p.encWalletAgeDays      = FHE.fromExternal(encWalletAge,       inputProof);
        p.encTxCount            = FHE.fromExternal(encTxCount,         inputProof);
        p.encRepaymentRatioBps  = FHE.fromExternal(encRepaymentRatio,  inputProof);
        p.encCollateralRatioBps = FHE.fromExternal(encCollateralRatio, inputProof);
        p.encDefaultCount       = FHE.fromExternal(encDefaultCount,    inputProof);

        // Grant persistent ACL: contract can operate on these ciphertexts
        FHE.allowThis(p.encWalletAgeDays);
        FHE.allowThis(p.encTxCount);
        FHE.allowThis(p.encRepaymentRatioBps);
        FHE.allowThis(p.encCollateralRatioBps);
        FHE.allowThis(p.encDefaultCount);

        // Grant the user read access to their own ciphertexts
        FHE.allow(p.encWalletAgeDays,      msg.sender);
        FHE.allow(p.encTxCount,            msg.sender);
        FHE.allow(p.encRepaymentRatioBps,  msg.sender);
        FHE.allow(p.encCollateralRatioBps, msg.sender);
        FHE.allow(p.encDefaultCount,       msg.sender);

        // Compute encrypted score immediately
        p.encComputedScore = _computeScore(
            p.encWalletAgeDays,
            p.encTxCount,
            p.encRepaymentRatioBps,
            p.encCollateralRatioBps,
            p.encDefaultCount
        );

        FHE.allowThis(p.encComputedScore);
        FHE.allow(p.encComputedScore, msg.sender);

        p.lastUpdated      = block.timestamp;
        p.decryptionPending = false;
        p.hasScore         = false;

        if (p.publicScore == 0) totalProfiles++;

        emit ProfileSubmitted(msg.sender, block.timestamp);
    }

    /**
     * @notice Request the encrypted score to be decrypted and revealed publicly.
     * @dev Triggers async DecryptionOracle flow. Score becomes public after callback.
     */
    function requestScoreDecryption() external {
        CreditProfile storage p = profiles[msg.sender];
        require(p.lastUpdated > 0,          "No profile submitted");
        require(!p.decryptionPending,        "Decryption already pending");

        bytes32[] memory cts = new bytes32[](1);
        cts[0] = FHE.toBytes32(p.encComputedScore);

        uint256 requestId = FHE.requestDecryption(cts, this.scoreDecryptionCallback.selector);

        requestToUser[requestId] = msg.sender;
        p.decryptionPending = true;

        emit ScoreRequested(msg.sender, requestId);
    }

    /**
     * @notice Callback invoked by the DecryptionOracle with the plaintext score.
     * @dev Only callable by the oracle (enforced by SepoliaConfig ACL).
     */
    function scoreDecryptionCallback(
        uint256      requestId,
        bytes memory cleartexts,
        bytes memory decryptionProof
    ) external returns (bool) {
        // Verify KMS signature on decryption result
        FHE.checkSignatures(requestId, cleartexts, decryptionProof);

        address user = requestToUser[requestId];
        require(user != address(0), "Unknown request");

        // Decode the single uint64 from ABI-encoded cleartexts
        uint64 rawScore = abi.decode(cleartexts, (uint64));

        // Clamp to valid FICO-like range
        if (rawScore < SCORE_MIN) rawScore = SCORE_MIN;
        if (rawScore > 850)       rawScore = 850;

        CreditProfile storage p = profiles[user];
        p.publicScore       = rawScore;
        p.hasScore          = true;
        p.decryptionPending = false;

        // Determine tier
        string memory tier;
        if (rawScore <= SCORE_POOR_MAX)      tier = "Poor";
        else if (rawScore <= SCORE_FAIR_MAX) tier = "Fair";
        else if (rawScore <= SCORE_GOOD_MAX) tier = "Good";
        else                                  tier = "Excellent";

        p.scoreTier = tier;
        totalDecryptions++;

        delete requestToUser[requestId];

        emit ScoreRevealed(user, rawScore, tier);
        return true;
    }

    // ─── Internal Score Engine ────────────────────────────────────────────────

    /**
     * @notice Compute a weighted credit score entirely on encrypted values.
     * @dev All arithmetic is performed using FHE operations — no plaintext is ever
     *      produced inside this function. The coprocessor processes the actual
     *      homomorphic operations off-chain.
     *
     * Score formula (all encrypted):
     *   base = 300
     *   + (repaymentRatioBps / 10000) * 350   → up to 350 pts  (35% weight × 1000)
     *   + (min(collateralRatioBps, 10000) / 10000) * 300  → up to 300 pts
     *   + (min(walletAgeDays, 3650) / 3650) * 150          → up to 150 pts
     *   + (min(txCount, 1000) / 1000) * 50                 → up to  50 pts
     *   - defaultCount * 20                                  → penalty
     *
     * Total range: 300 – 850 (intentionally FICO-like)
     */
    function _computeScore(
        euint64 walletAge,
        euint64 txCount,
        euint64 repaymentBps,
        euint64 collateralBps,
        euint64 defaultCount
    ) internal returns (euint64) {
        // Base score — plaintext 300 lifted into ciphertext space
        euint64 score = FHE.asEuint64(300);

        // ── Repayment component (max 350 pts) ─────────────────────────────────
        // (repaymentBps / 10000) * 350 = repaymentBps * 350 / 10000 = repaymentBps * 7 / 200
        // We use integer arithmetic: repaymentBps * 7 / 200
        euint64 repayPoints = FHE.div(FHE.mul(repaymentBps, 7), 200);
        // Cap at 350
        euint64 repayMax    = FHE.asEuint64(350);
        repayPoints         = FHE.min(repayPoints, repayMax);
        score               = FHE.add(score, repayPoints);

        // ── Collateral component (max 300 pts) ────────────────────────────────
        // Cap collateralBps at 10000 (100%), then (capped / 10000) * 300 = capped * 3 / 100
        euint64 collateralCap = FHE.asEuint64(10000);
        euint64 cappedColl    = FHE.min(collateralBps, collateralCap);
        euint64 collPoints    = FHE.div(FHE.mul(cappedColl, 3), 100);
        euint64 collMax       = FHE.asEuint64(300);
        collPoints            = FHE.min(collPoints, collMax);
        score                 = FHE.add(score, collPoints);

        // ── Wallet age component (max 150 pts) ────────────────────────────────
        // Cap walletAge at 3650 days, then (capped / 3650) * 150 ≈ capped * 150 / 3650
        // Simplified: capped * 3 / 73  (150/3650 = 3/73)
        euint64 ageCap    = FHE.asEuint64(3650);
        euint64 cappedAge = FHE.min(walletAge, ageCap);
        euint64 agePoints = FHE.div(FHE.mul(cappedAge, 3), 73);
        euint64 ageMax    = FHE.asEuint64(150);
        agePoints         = FHE.min(agePoints, ageMax);
        score             = FHE.add(score, agePoints);

        // ── Transaction count component (max 50 pts) ─────────────────────────
        // Cap txCount at 1000, then (capped / 1000) * 50 = capped / 20
        euint64 txCap     = FHE.asEuint64(1000);
        euint64 cappedTx  = FHE.min(txCount, txCap);
        euint64 txPoints  = FHE.div(cappedTx, 20);
        euint64 txMax     = FHE.asEuint64(50);
        txPoints          = FHE.min(txPoints, txMax);
        score             = FHE.add(score, txPoints);

        // ── Default penalty (-20 pts each, floor at SCORE_MIN) ───────────────
        // Cap defaultCount at 27 to avoid underflow (27 * 20 = 540 max penalty)
        euint64 defaultCap      = FHE.asEuint64(27);
        euint64 cappedDefaults  = FHE.min(defaultCount, defaultCap);
        euint64 penalty         = FHE.mul(cappedDefaults, 20);

        // FHE.select: if score > penalty, subtract; else clamp to SCORE_MIN
        ebool   canSubtract     = FHE.gt(score, penalty);
        euint64 penaltyFloor    = FHE.asEuint64(SCORE_MIN);
        euint64 subtracted      = FHE.sub(score, penalty);
        score                   = FHE.select(canSubtract, subtracted, penaltyFloor);

        // Final clamp: score must be ≥ 300 and ≤ 850
        euint64 hardFloor = FHE.asEuint64(SCORE_MIN);
        euint64 hardCeil  = FHE.asEuint64(850);
        score             = FHE.max(score, hardFloor);
        score             = FHE.min(score, hardCeil);

        return score;
    }

    // ─── View Functions ───────────────────────────────────────────────────────

    /**
     * @notice Get public score data for any address (only available after decryption).
     */
    function getPublicScore(address user) external view returns (
        bool   hasScore,
        uint64 score,
        string memory tier,
        uint256 lastUpdated,
        bool   decryptionPending
    ) {
        CreditProfile storage p = profiles[user];
        return (
            p.hasScore,
            p.publicScore,
            p.scoreTier,
            p.lastUpdated,
            p.decryptionPending
        );
    }

    /**
     * @notice Check if an address has a profile.
     */
    function hasProfile(address user) external view returns (bool) {
        return profiles[user].lastUpdated > 0;
    }

    /**
     * @notice Protocol-level stats.
     */
    function getStats() external view returns (
        uint256 profileCount,
        uint256 decryptionCount
    ) {
        return (totalProfiles, totalDecryptions);
    }
}
