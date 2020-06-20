const express = require('express')
const AWSXRay = require('aws-xray-sdk')
const axios = require('axios');
const app = express()

// Loading configuration file from .env file or environment variables
require('dotenv').config();
const xrayEnabled = process.env.ENABLE_XRAY_TRACING || "false";
const appType = process.env.APP_TYPE || "backend";
const appVersion = process.env.APP_VERSION || "v1";
const appPort = process.env.APP_PORT || "3000";
const appPath = process.env.APP_PATH || "app";
const appBackends = process.env.APP_BACKENDS || "";

if (xrayEnabled == "true") {
  AWSXRay.captureHTTPsGlobal(require('http'));
  AWSXRay.captureHTTPsGlobal(require('https'));
  AWSXRay.capturePromise();
}

const sendRequest = async (url) => {
  try {
    const response = await axios.get(`${url}`)
    if (response.status != 200){
      throw `Got HTTP status ${response.status} from ${url}`
    } else {
      return response.data
    }
  } catch (errorMessage) {
    return [{
      error: errorMessage
    }]
  }
};

// We do not want healthcheck endpoint to be captured by x-ray
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

if (xrayEnabled == "true") {
  const segmentName = `${appType}-${appVersion}`
  app.use(AWSXRay.express.openSegment(segmentName));
}

app.get('/:path', async (req, res) => {
  try {
    if (req.params.path == appPath) {
      const backends = appBackends.split(";");
      let result = [
        {
          [appType]: appVersion
        }
      ];

      for (let i = 0; i < backends.length; i++){
        const downstream = await sendRequest(backends[i]);
        result = result.concat(downstream);
      }

      res.status(200).json(result);
    } else {
      res.status(404).json({ message: `path ${req.params.path} not found` });
    }
  } catch (errorMessage){
    return {
      error: errorMessage
    }
  }
});

if (xrayEnabled == "true") {
  app.use(AWSXRay.express.closeSegment());
}

app.listen(appPort, () => console.log(`Example app listening on port ${appPort}!`))