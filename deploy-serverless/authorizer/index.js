/**
 * JWT Lambda Authorizer for MyTutorial API Gateway (HTTP API).
 *
 * Validates Bearer JWT tokens using the same HMAC-SHA512 secret
 * shared across all services. Returns an IAM policy allowing or
 * denying access to the requested API route.
 *
 * Expects:
 *   Authorization: Bearer <token>
 *
 * Returns on success:
 *   principalId: username (JWT subject)
 *   context: { username, email? }
 */

const crypto = require('crypto');

// JWT secret — must match app.jwt.secret in Spring Boot config
const JWT_SECRET = process.env.JWT_SECRET || '3f8a2b1c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a';

/**
 * Base64 URL-decode
 */
function base64UrlDecode(str) {
  str = str.replace(/-/g, '+').replace(/_/g, '/');
  switch (str.length % 4) {
    case 0: break;
    case 2: str += '=='; break;
    case 3: str += '='; break;
    default: throw new Error('Invalid base64 string');
  }
  return Buffer.from(str, 'base64').toString('utf8');
}

/**
 * Verify HMAC-SHA512 signature
 */
function verifySignature(header, payload, signature) {
  const key = Buffer.from(JWT_SECRET, 'utf8');
  const expected = crypto
    .createHmac('sha512', key)
    .update(`${header}.${payload}`)
    .digest('base64url');
  return crypto.timingSafeEqual(
    Buffer.from(expected),
    Buffer.from(signature)
  );
}

/**
 * Lambda handler
 */
exports.handler = async (event) => {
  try {
    // Extract token from Authorization header
    const authHeader = event.headers?.authorization || event.headers?.Authorization || '';
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    if (!match) {
      throw new Error('Missing or malformed Authorization header');
    }
    const token = match[1];

    // Decode JWT parts
    const parts = token.split('.');
    if (parts.length !== 3) {
      throw new Error('Invalid JWT format');
    }

    const [headerB64, payloadB64, signatureB64] = parts;
    const header = JSON.parse(base64UrlDecode(headerB64));
    const payload = JSON.parse(base64UrlDecode(payloadB64));

    // Verify algorithm
    if (header.alg !== 'HS512') {
      throw new Error(`Unexpected algorithm: ${header.alg}`);
    }

    // Verify signature
    if (!verifySignature(headerB64, payloadB64, signatureB64)) {
      throw new Error('Invalid signature');
    }

    // Check expiration
    const now = Math.floor(Date.now() / 1000);
    if (payload.exp && payload.exp < now) {
      throw new Error('Token expired');
    }

    // Extract username from subject
    const username = payload.sub;
    if (!username) {
      throw new Error('Token missing subject');
    }

    // Generate IAM policy — allow access to the requested route
    const methodArn = event.routeArn;
    const policy = generateAllowPolicy(username, methodArn);

    // Return with context that API Gateway forwards as headers
    return {
      ...policy,
      context: {
        username,
        // email is not embedded in the token, but could be looked up
      },
    };
  } catch (err) {
    console.error('Auth denied:', err.message);
    // Return a deny policy
    return generateDenyPolicy('anonymous', event.routeArn);
  }
};

function generateAllowPolicy(principalId, resource) {
  return {
    principalId,
    policyDocument: {
      Version: '2012-10-17',
      Statement: [
        {
          Action: 'execute-api:Invoke',
          Effect: 'Allow',
          Resource: resource,
        },
      ],
    },
  };
}

function generateDenyPolicy(principalId, resource) {
  return {
    principalId,
    policyDocument: {
      Version: '2012-10-17',
      Statement: [
        {
          Action: 'execute-api:Invoke',
          Effect: 'Deny',
          Resource: resource,
        },
      ],
    },
  };
}
