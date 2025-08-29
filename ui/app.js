let contract;
let provider;
let signer;
let whitelist;
let userStatus = 'New User';
let roles = {};
let contractAddress;

const roleMap = {
    user: [
        'applyForCeo',
        'createFundingRequest',
        'registerEndorserCandidate',
        'voteForEndorser',
        'challengeEndorser',
        'voteOnCeoByUser',
        'voteOnFundingByUser',
        'finalizeCeoVote',
        'activateElectedCeo',
        'executeFundingRequest',
        'claimReward',
        'exchangeInvUsdForInv'
    ],
    endorser: [
        'voteOnCeoByEndorser',
        'voteOnFundingByEndorser'
    ],
    ceo: [
        'makeWhitelisted',
        'setTreasuryOwner',
        'setPriceFeed',
        'setDailyExchangeLimit',
        'approveFundingRequest'
    ]
};

function classifyFunction(name) {
    for (const role of Object.keys(roleMap)) {
        if (roleMap[role].includes(name)) {
            return role;
        }
    }
    return 'user';
}

const dashboardMetrics = [
    { id: 'proposal-count', contractFn: 'getProposalCount', format: val => val.toString() },
    { id: 'fund-balance', contractFn: 'getBalance', format: val => ethers.utils.formatEther(val) + ' ETH' },
];

async function loadEndorsers() {
    try {
        const endorsers = await contract.activeEndorserList();
        const tbody = document.getElementById('endorser-table');
        tbody.innerHTML = '';
        for (const addr of endorsers) {
            const votes = await contract.getVotes(addr);
            const row = document.createElement('tr');
            const a = document.createElement('td');
            a.textContent = addr;
            const v = document.createElement('td');
            v.textContent = votes.toString();
            row.appendChild(a);
            row.appendChild(v);
            tbody.appendChild(row);
        }
    } catch (err) {
        console.error('Failed to load endorsers:', err);
    }
}

// Check if ethers is loaded
if (typeof ethers === 'undefined') {
    console.error('ethers.js is not loaded. Please ensure the CDN script is included in index.html.');
    alert('ethers.js failed to load. Please refresh the page or check your internet connection.');
}

async function loadContractAddress() {
    try {
        console.log('Attempting to fetch deployInfo.json');
        const response = await fetch('deployInfo.json');
        if (!response.ok) {
            throw new Error(`Failed to fetch deployInfo.json: ${response.statusText}`);
        }
        const info = await response.json();
        contractAddress = info.address;
    } catch (err) {
        console.error('Failed to load contract address:', err);
        showStatus('Failed to load contract address. Check console for details.', 'error');
        throw err; // Re-throw to halt execution if needed
    }
}

async function connectWallet() {
    if (!window.ethereum) {
        showStatus('MetaMask not detected. Please install MetaMask.', 'error');
        return false;
    }
    provider = new ethers.providers.Web3Provider(window.ethereum);
    try {
        await provider.send('eth_requestAccounts', []);
    } catch (err) {
        showStatus(`Wallet connection failed: ${err.message || err}`, 'error');
        return false;
    }
    signer = provider.getSigner();
    const address = await signer.getAddress();
    document.getElementById('connection').innerText = `Connected: ${address}`;
    try {
        await loadContractAddress();
        console.log('Attempting to fetch INVTRON_DAO.json');
        const response = await fetch('INVTRON_DAO.json');
        if (!response.ok) {
            throw new Error(`Failed to fetch INVTRON_DAO.json: ${response.statusText}`);
        }
        const artifact = await response.json();
        contract = new ethers.Contract(contractAddress, artifact.abi, signer);
        roles.ceo = await contract.CEO_ROLE();
        roles.endorser = await contract.ENDORSER_ROLE();
        const whitelistAddr = await contract.whitelistManager();
        whitelist = new ethers.Contract(
            whitelistAddr,
            ['function isWhitelisted(address) view returns (bool)'],
            signer
        );
        await updateStatus(address);
        renderFunctions(artifact.abi);
        updateDashboard();
        loadEndorsers();
        showStatus('Wallet connected', 'success');
        return true;
    } catch (err) {
        console.error('Contract initialization failed:', err);
        showStatus('Failed to initialize contract. Check console for details.', 'error');
        return false;
    }
}

async function updateStatus(address) {
    userStatus = 'New User';
    try {
        if (await contract.hasRole(roles.ceo, address)) {
            userStatus = 'Active CEO';
        } else if (await contract.hasRole(roles.endorser, address)) {
            userStatus = 'Active Endorser';
        } else if (await whitelist.isWhitelisted(address)) {
            userStatus = 'Whitelisted User';
        }
    } catch (err) {
        console.error('Role check failed:', err);
    }
    document.getElementById('connection').innerText += ` - ${userStatus}`;
}

function renderFunctions(abi) {
    const containers = {
        user: document.getElementById('functions-user'),
        endorser: document.getElementById('functions-endorser'),
        ceo: document.getElementById('functions-ceo')
    };
    Object.values(containers).forEach(c => (c.innerHTML = ''));
    abi.filter(i => i.type === 'function').forEach(fn => {
        const role = classifyFunction(fn.name);
        containers[role].appendChild(createFunctionElement(fn));
    });
}

function createInput(form, input, name) {
    const label = document.createElement('label');
    label.textContent = `${name} (${input.type})`;
    form.appendChild(label);
    if (input.type === 'bool') {
        const container = document.createElement('div');
        const up = document.createElement('button');
        up.type = 'button';
        up.textContent = '↑';
        const down = document.createElement('button');
        down.type = 'button';
        down.textContent = '↓';
        const hidden = document.createElement('input');
        hidden.type = 'hidden';
        hidden.name = name;
        up.addEventListener('click', () => { hidden.value = true; form.requestSubmit(); });
        down.addEventListener('click', () => { hidden.value = false; form.requestSubmit(); });
        container.appendChild(up);
        container.appendChild(down);
        form.appendChild(container);
        form.appendChild(hidden);
    } else if (input.type === 'tuple') {
        input.components.forEach(comp => {
            createInput(form, comp, `${name}.${comp.name}`);
        });
    } else {
        const inputEl = document.createElement('input');
        inputEl.name = name;
        form.appendChild(inputEl);
    }
}

function collectInput(form, input, name) {
    if (input.type === 'tuple') {
        const obj = {};
        input.components.forEach(comp => {
            obj[comp.name] = collectInput(form, comp, `${name}.${comp.name}`);
        });
        return obj;
    }
    return form.elements[name].value;
}

function createFunctionElement(fn) {
    const div = document.createElement('div');
    div.className = 'function';
    const title = document.createElement('h3');
    title.textContent = `${fn.name} (${fn.stateMutability})`;
    div.appendChild(title);
    const form = document.createElement('form');
    fn.inputs.forEach(input => {
        createInput(form, input, input.name);
    });
    const submit = document.createElement('button');
    submit.textContent = fn.stateMutability === 'view' || fn.stateMutability === 'pure' ? 'Read' : 'Write';
    form.appendChild(submit);
    form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const args = fn.inputs.map(input => collectInput(form, input, input.name));
        if (!validateInputs(fn, args)) return;
        try {
            if (fn.stateMutability === 'view' || fn.stateMutability === 'pure') {
                const result = await contract[fn.name](...args);
                alert(JSON.stringify(result));
            } else {
                showStatus('Sending transaction...', 'info');
                const gasEstimate = await contract.estimateGas[fn.name](...args);
                showStatus(`Estimated gas: ${gasEstimate.toString()}`, 'info');
                const tx = await contract[fn.name](...args, { gasLimit: gasEstimate });
                await tx.wait();
                const network = await provider.getNetwork();
                const explorer = getExplorerUrl(network.chainId);
                if (explorer) {
                    showStatus(`Transaction confirmed: <a href="${explorer}${tx.hash}" target="_blank">View on Explorer</a>`, 'success');
                } else {
                    showStatus('Transaction confirmed', 'success');
                }
            }
        } catch (err) {
            showStatus(err.message || err, 'error');
        }
    });
    div.appendChild(form);
    return div;
}

function validateInputs(fn, args) {
    for (let i = 0; i < fn.inputs.length; i++) {
        const input = fn.inputs[i];
        const value = args[i];
        if (!validateValue(input, value, input.name)) return false;
    }
    return true;
}

function validateValue(input, value, name) {
    if (input.type === 'tuple') {
        for (const comp of input.components) {
            if (!validateValue(comp, value[comp.name], `${name}.${comp.name}`)) return false;
        }
        return true;
    }
    if (input.type === 'address' && !ethers.utils.isAddress(value)) {
        showStatus(`Invalid address for ${name}`, 'error');
        return false;
    }
    if (input.type.startsWith('uint') && (isNaN(value) || Number(value) < 0)) {
        showStatus(`Invalid number for ${name}`, 'error');
        return false;
    }
    return true;
}

function getExplorerUrl(chainId) {
    const explorers = {
        1: 'https://etherscan.io/tx/',
        11155111: 'https://sepolia.etherscan.io/tx/',
    };
    return explorers[chainId] || '';
}

async function updateDashboard() {
    for (const metric of dashboardMetrics) {
        try {
            const value = await contract[metric.contractFn]();
            document.getElementById(metric.id).innerText = metric.format(value);
        } catch (err) {
            console.error(`Failed to fetch ${metric.id}:`, err);
        }
    }
}

function showTutorial() {
    alert('Welcome to the DAO! Use the tabs to navigate roles, connect your wallet, and vote on proposals.');
}

function showStatus(message, type = 'info') {
    const status = document.getElementById('status');
    status.className = type;
    status.innerHTML = message;
    status.style.display = 'block';
    setTimeout(() => {
        status.style.display = 'none';
    }, 5000);
}

async function handleTabClick(tab, button) {
    const connected = await connectWallet();
    if (!connected) return;
    const address = await signer.getAddress();
    await updateStatus(address);
    const expected = userStatus === 'Active CEO' ? 'ceo' :
                     userStatus === 'Active Endorser' ? 'endorser' : 'user';
    if (tab !== 'user' && tab !== expected) {
        showStatus(`You are ${userStatus}. Please use the ${expected.charAt(0).toUpperCase() + expected.slice(1)} tab.`, 'error');
        return;
    }
    showTab(tab, button);
}

function showTab(tab, button) {
    document.querySelectorAll('#tabs button').forEach(b => b.classList.remove('active'));
    button.classList.add('active');
    document.querySelectorAll('.tab-content').forEach(div => div.style.display = 'none');
    document.getElementById(`functions-${tab}`).style.display = 'block';
}

document.getElementById('connect-button').addEventListener('click', connectWallet);
document.querySelectorAll('#tabs button').forEach(btn => {
    btn.addEventListener('click', () => handleTabClick(btn.dataset.tab, btn));
});