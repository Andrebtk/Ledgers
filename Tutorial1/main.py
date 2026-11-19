from re import L
import json
from hashlib import sha256


FIRST_BLOCK_TIMESTAMP = 1697412600
NULL_HASH = "0x" + "0" * 64

# each following block has timestamp + 10
def createBlockHeader():
    return



def createBlock():
    return 



def load_memPool():
    with open('mempool.json') as f:
        mempool = json.load(f)
    
    return mempool

def load_blockChain():
    with open('blockchain.json') as f:
        blockchain = json.load(f)
    return blockchain

def load_keys():
    with open('keys.json') as f:
        keys = json.load(f)
    return keys



def get_100_transactions(blockChain):

    latest_block = blockChain[-1]
    latest_block_timestamp = latest_block["header"]["timestamp"]

    new_block_timestamp = latest_block_timestamp + 10

    # Valid transactions
    executables_txs = [
        tx for tx in mempool 
        if tx['lock_time'] <= new_block_timestamp
    ]

    # Order executables_txs by highest gas fees
    executables_txs.sort(key=lambda tx: tx["transaction_fee"], reverse=True)

    # We get the first 100
    first_100_blocks = executables_txs[:100]

    return first_100_blocks

def hash_transactions(tx):
    raw_str = ",".join(str(tx[key]) for key in sorted(tx.keys()))
    return "0x" + sha256(raw_str.encode()).hexdigest()

def list_txs_hashed(txs):
    list = []
    for tx in txs:
        list.append(hash_transactions(tx))
    return list




def H(a, b):
    hash = a + b if a < b else b + a
    return "0x" + sha256(hash.encode()).hexdigest()

def compute_merkle_root(tx_hashes):
    if not tx_hashes:
        return NULL_HASH

    
    current_level = tx_hashes[:]
    while len(current_level) > 1:
        if len(current_level) % 2 != 0:
            current_level.append(NULL_HASH)
        
        next_level = []
        for i in range(0, len(current_level), 2):
            next_level.append(H(current_level[i], current_level[i + 1]))
        
        current_level = next_level
    
    return current_level[0]



def create_block_header(blockChain, transactions_merkle_root, transactions_count, miner_address):
    latest_block = blockChain[-1]

    height = latest_block["header"]["height"] + 1
    previous_block_header_hash = latest_block["header"]["hash"]
    timestamp = latest_block["header"]["timestamp"] + 10
    difficulty = min (6, 1 + height // 50)

    # POW

    target = "0" * difficulty 
    nonce = 0

    while True:
        raw_str = (
            f"{difficulty},{height},{miner_address},{nonce},"
            f"{previous_block_header_hash},{timestamp},{transactions_count},"
            f"{transactions_merkle_root}"
        )

        block_hash = "0x" + sha256(raw_str.encode()).hexdigest()
        if block_hash[2:].startswith(target):
            break
        nonce += 1
    
    return {
        "difficulty": difficulty,
        "hash": block_hash,
        "height": height,
        "miner": miner_address,
        "nonce": nonce,
        "previous_block_header_hash": previous_block_header_hash,
        "timestamp": timestamp,
        "transactions_count": transactions_count,
        "transactions_merkle_root": transactions_merkle_root
    }

def create_block(header, transactions):
    return {
        "header": header,
        "transactions": transactions
    }


def save_blockchain(blockChain):
    miner = list(keys.keys())[0]
    header = create_block_header(blockChain, merkle_root, len(firsts_transaction), miner)
    new_block = create_block(header, firsts_transaction)


    blockChain.append(new_block)
    included_sig = {tx["signature"] for tx in firsts_transaction}
    remaining_mempool = [tx for tx in mempool if tx["signature"] not in included_sig]


    with open("new_blockchain.json", "w") as f:
        json.dump(blockChain, f , indent=2)

    with open("new_mempool.json", "w") as f:
        json.dump(remaining_mempool, f, indent=2)



# MAIN
mempool = load_memPool()
blockChain = load_blockChain()
keys = load_keys()

# Step 1 (a)
firsts_transaction = get_100_transactions(blockChain)

# step 1 (b)
hashed_transactions = list_txs_hashed(firsts_transaction)

# Now we create the merkle tree
merkle_root = compute_merkle_root(hashed_transactions)
print(merkle_root)


# We create a new block step 1 (c)
save_blockchain(blockChain)