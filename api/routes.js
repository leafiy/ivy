import express from 'express';
import config from './config/index.js';
import authenticateClient from './middleware/auth.js';
import authenticateAdmin from './middleware/adminAuth.js';
import { requireWebCsrf } from './middleware/browserSession.js';
import { asyncHandler } from './middleware/validate.js';
import { createRateLimiter, requestIp } from './services/rateLimit.js';
import * as authController from './controllers/auth.js';
import * as syncController from './controllers/sync.js';
import * as notesController from './controllers/notes.js';
import * as eventsController from './controllers/events.js';
import * as uploadController from './controllers/upload.js';
import * as orderController from './controllers/order.js';
import * as adminController from './controllers/admin.js';

const router = express.Router();
const apiPrefix = '/api/v1';
const adminApiPrefix = '/admin-api/v1';
const policyLimiter = (scope, policyName, key) => {
  const policy = config.rateLimit.policies[policyName];
  return createRateLimiter({
    scope,
    limit: policy.max,
    windowMs: policy.windowMs,
    key,
  });
};

const namespaceCreateIpLimit = policyLimiter(
  'namespace-create-ip',
  'namespaceCreateIp',
  requestIp
);
const namespaceCreateDeviceLimit = policyLimiter(
  'namespace-create-device',
  'namespaceCreateDevice',
  (req) => req.body?.device?.id
);
const namespaceLoginLimit = policyLimiter(
  'namespace-login-ip',
  'namespaceLoginIp',
  requestIp
);
const emailCooldownLimit = policyLimiter(
  'email-code-cooldown',
  'emailCooldown',
  (req) => String(req.body?.email || '').trim().toLowerCase()
);
const emailDailyAddressLimit = policyLimiter(
  'email-code-daily-address',
  'emailDailyAddress',
  (req) => String(req.body?.email || '').trim().toLowerCase()
);
const emailDailyIpLimit = policyLimiter(
  'email-code-daily-ip',
  'emailDailyIp',
  requestIp
);
const uploadGrantLimit = policyLimiter(
  'upload-grant-user',
  'uploadGrant',
  (req) => req.userId?.toString()
);
const syncLimit = policyLimiter(
  'sync-user',
  'authenticatedSync',
  (req) => req.userId?.toString()
);

router.post(
  `${apiPrefix}/namespaces`,
  namespaceCreateIpLimit,
  namespaceCreateDeviceLimit,
  asyncHandler(authController.createNamespace)
);
router.post(
  `${apiPrefix}/auth/login/namespace`,
  namespaceLoginLimit,
  asyncHandler(authController.loginNamespace)
);
router.post(`${apiPrefix}/auth/login/email`, asyncHandler(authController.loginWithEmail));
router.get(`${apiPrefix}/auth/config`, asyncHandler(authController.authConfig));
router.post(`${apiPrefix}/auth/oauth/google`, asyncHandler(authController.oauthGoogle));
router.post(`${apiPrefix}/auth/oauth/google/start`, asyncHandler(authController.startGoogleOAuth));
router.get(`${apiPrefix}/auth/oauth/google/callback`, asyncHandler(authController.googleOAuthCallback));
router.post(`${apiPrefix}/auth/oauth/exchange`, asyncHandler(authController.exchangeOAuthCode));
router.post(`${apiPrefix}/auth/register`, asyncHandler(authController.register));
router.post(
  `${apiPrefix}/auth/email-code`,
  emailCooldownLimit,
  emailDailyAddressLimit,
  emailDailyIpLimit,
  asyncHandler(authController.sendEmailCode)
);
router.post(
  `${apiPrefix}/auth/refresh`,
  requireWebCsrf,
  asyncHandler(authController.refresh)
);
router.post(
  `${apiPrefix}/auth/logout`,
  requireWebCsrf,
  asyncHandler(authController.logout)
);
router.get(`${apiPrefix}/auth/me`, authenticateClient, asyncHandler(authController.me));

router.get(
  `${apiPrefix}/sync/database`,
  authenticateClient,
  syncLimit,
  asyncHandler(syncController.databaseStatus)
);
router.post(
  `${apiPrefix}/sync/database`,
  authenticateClient,
  syncLimit,
  syncController.uploadDatabaseMiddleware,
  asyncHandler(syncController.uploadDatabase)
);
// The browser client speaks notes, not snapshots. Everything under here runs
// through the same bridge the macOS upload path feeds, so the two clients can
// never disagree about what the account holds.
// Deliberately outside syncLimit: a stream is one request that then lives for
// minutes, and counting it against a per-minute budget would punish exactly
// the clients behaving best.
router.get(`${apiPrefix}/sync/events`, authenticateClient, asyncHandler(eventsController.streamNoteEvents));

router.get(`${apiPrefix}/notes`, authenticateClient, syncLimit, asyncHandler(notesController.listNotes));
router.post(`${apiPrefix}/notes`, authenticateClient, syncLimit, asyncHandler(notesController.createNote));
router.post(`${apiPrefix}/notes/flush`, authenticateClient, syncLimit, asyncHandler(notesController.flushNoteDatabase));
router.patch(`${apiPrefix}/notes/:id`, authenticateClient, syncLimit, asyncHandler(notesController.updateNote));
router.delete(`${apiPrefix}/notes/:id`, authenticateClient, syncLimit, asyncHandler(notesController.deleteNote));
router.post(`${apiPrefix}/notes/:id/restore`, authenticateClient, syncLimit, asyncHandler(notesController.restoreNote));

router.get(
  `${apiPrefix}/upload/authorization`,
  authenticateClient,
  uploadGrantLimit,
  asyncHandler(uploadController.uploadAuthorization)
);
router.post(`${apiPrefix}/upload/files`, authenticateClient, asyncHandler(uploadController.uploadFiles));
router.get(`${apiPrefix}/upload/quota`, authenticateClient, asyncHandler(uploadController.attachmentQuota));
router.delete(`${apiPrefix}/upload/files`, authenticateClient, asyncHandler(uploadController.deleteFile));

router.get(`${apiPrefix}/plans`, asyncHandler(orderController.listPlans));
router.post(`${apiPrefix}/orders/stripe/checkout`, authenticateClient, asyncHandler(orderController.createStripeCheckout));
router.post(`${apiPrefix}/orders/wechat/prepay`, authenticateClient, asyncHandler(orderController.createWechatPrepay));
router.get(`${apiPrefix}/orders/:id`, authenticateClient, asyncHandler(orderController.getOrder));
router.post(`${apiPrefix}/webhooks/stripe`, asyncHandler(orderController.stripeWebhook));
router.post(`${apiPrefix}/webhooks/wechat`, asyncHandler(orderController.wechatWebhook));

router.post(`${adminApiPrefix}/login`, asyncHandler(adminController.login));
router.post(`${adminApiPrefix}/refresh`, authenticateAdmin, asyncHandler(adminController.refresh));
router.get(`${adminApiPrefix}/plans`, authenticateAdmin, asyncHandler(adminController.listPlans));
router.post(`${adminApiPrefix}/plans`, authenticateAdmin, asyncHandler(adminController.createPlan));
router.put(`${adminApiPrefix}/plans`, authenticateAdmin, asyncHandler(adminController.updatePlan));
router.delete(`${adminApiPrefix}/plans`, authenticateAdmin, asyncHandler(adminController.deletePlan));
router.put(`${adminApiPrefix}/plans/:planId`, authenticateAdmin, asyncHandler(adminController.updatePlan));
router.delete(`${adminApiPrefix}/plans/:planId`, authenticateAdmin, asyncHandler(adminController.deletePlan));
router.get(`${adminApiPrefix}/users`, authenticateAdmin, asyncHandler(adminController.listUsers));
router.get(`${adminApiPrefix}/orders`, authenticateAdmin, asyncHandler(adminController.listOrders));
router.post(`${adminApiPrefix}/orders/:id/refund-mark`, authenticateAdmin, asyncHandler(adminController.refundMark));

export default router;
