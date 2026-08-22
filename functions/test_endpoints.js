const https = require('https');

const API_KEY = "AIzaSyD9kg-3Q5Etl9GQ_EJqvw2MQvyogCDeCqw";

function makeRequest(url, method, headers, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, { method, headers }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve({ status: res.statusCode, data }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function run() {
  console.log("Acquiring ID Token...");
  const signUpRes = await makeRequest(`https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}`, 'POST', { 'Content-Type': 'application/json' }, '{"returnSecureToken":true}');
  const idToken = JSON.parse(signUpRes.data).idToken;
  if (!idToken) throw new Error("Failed to get ID token: " + signUpRes.data);

  console.log("--- getMetaWhatsappClientConfig ---");
  const configRes = await makeRequest('https://us-central1-aivy-5c031.cloudfunctions.net/getMetaWhatsappClientConfig', 'POST', {
    'Authorization': `Bearer ${idToken}`,
    'Content-Type': 'application/json'
  }, '{"data":{}}');
  console.log(`Status: ${configRes.status}`);
  console.log(`Response: ${configRes.data}\n`);

  console.log("--- completeWhatsappEmbeddedSignup ---");
  const signupRes = await makeRequest('https://us-central1-aivy-5c031.cloudfunctions.net/completeWhatsappEmbeddedSignup', 'POST', {
    'Authorization': `Bearer ${idToken}`,
    'Content-Type': 'application/json'
  }, '{"data":{}}');
  console.log(`Status: ${signupRes.status}`);
  console.log(`Response: ${signupRes.data}\n`);

  console.log("--- whatsappWebhook ---");
  const webhookRes = await makeRequest('https://whatsappwebhook-lgdohswcjq-uc.a.run.app', 'GET', {}, null);
  console.log(`Status: ${webhookRes.status}`);
  console.log(`Response: ${webhookRes.data}\n`);
}

run().catch(console.error);
