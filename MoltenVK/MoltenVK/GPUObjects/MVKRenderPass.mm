/*
 * MVKRenderPass.mm
 *
 * Copyright (c) 2015-2020 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKRenderPass.h"
#include "MVKFramebuffer.h"
#include "MVKCommandBuffer.h"
#include "MVKFoundation.h"
#include "mvk_datatypes.hpp"

using namespace std;


#pragma mark -
#pragma mark MVKRenderSubpass

MVKVulkanAPIObject* MVKRenderSubpass::getVulkanAPIObject() { return _renderPass->getVulkanAPIObject(); };

VkFormat MVKRenderSubpass::getColorAttachmentFormat(uint32_t colorAttIdx) {
	if (colorAttIdx < _colorAttachments.size()) {
		uint32_t rpAttIdx = _colorAttachments[colorAttIdx].attachment;
		if (rpAttIdx == VK_ATTACHMENT_UNUSED) { return VK_FORMAT_UNDEFINED; }
		return _renderPass->_attachments[rpAttIdx].getFormat();
	}
	return VK_FORMAT_UNDEFINED;
}

bool MVKRenderSubpass::isColorAttachmentUsed(uint32_t colorAttIdx) {
	if (colorAttIdx >= _colorAttachments.size()) {
		return false;
	}
	return _colorAttachments[colorAttIdx].attachment != VK_ATTACHMENT_UNUSED;
}

VkFormat MVKRenderSubpass::getDepthStencilFormat() {
	uint32_t rpAttIdx = _depthStencilAttachment.attachment;
	if (rpAttIdx == VK_ATTACHMENT_UNUSED) { return VK_FORMAT_UNDEFINED; }
	return _renderPass->_attachments[rpAttIdx].getFormat();
}

VkSampleCountFlagBits MVKRenderSubpass::getSampleCount() {
	for (auto& ca : _colorAttachments) {
		uint32_t rpAttIdx = ca.attachment;
		if (rpAttIdx != VK_ATTACHMENT_UNUSED) {
			return _renderPass->_attachments[rpAttIdx].getSampleCount();
		}
	}
	uint32_t rpAttIdx = _depthStencilAttachment.attachment;
	if (rpAttIdx != VK_ATTACHMENT_UNUSED) {
		return _renderPass->_attachments[rpAttIdx].getSampleCount();
	}

	return VK_SAMPLE_COUNT_1_BIT;
}

void MVKRenderSubpass::populateMTLRenderPassDescriptor(MTLRenderPassDescriptor* mtlRPDesc,
													   MVKFramebuffer* framebuffer,
													   const MVKArrayRef<VkClearValue>& clearValues,
													   bool isRenderingEntireAttachment,
													   bool loadOverride,
													   bool storeOverride) {
	MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();

	// Populate the Metal color attachments
	uint32_t caCnt = getColorAttachmentCount();
	uint32_t caUsedCnt = 0;
	for (uint32_t caIdx = 0; caIdx < caCnt; caIdx++) {
		uint32_t clrRPAttIdx = _colorAttachments[caIdx].attachment;
        if (clrRPAttIdx != VK_ATTACHMENT_UNUSED) {
			++caUsedCnt;
            MTLRenderPassColorAttachmentDescriptor* mtlColorAttDesc = mtlRPDesc.colorAttachments[caIdx];

            // If it exists, configure the resolve attachment first,
            // as it affects how the store action of the color attachment.
            uint32_t rslvRPAttIdx = _resolveAttachments.empty() ? VK_ATTACHMENT_UNUSED : _resolveAttachments[caIdx].attachment;
            bool hasResolveAttachment = (rslvRPAttIdx != VK_ATTACHMENT_UNUSED);
            if (hasResolveAttachment) {
                framebuffer->getAttachment(rslvRPAttIdx)->populateMTLRenderPassAttachmentDescriptorResolve(mtlColorAttDesc);
            }

            // Configure the color attachment
            MVKRenderPassAttachment* clrMVKRPAtt = &_renderPass->_attachments[clrRPAttIdx];
			framebuffer->getAttachment(clrRPAttIdx)->populateMTLRenderPassAttachmentDescriptor(mtlColorAttDesc);
			if (clrMVKRPAtt->populateMTLRenderPassAttachmentDescriptor(mtlColorAttDesc, this,
                                                                       isRenderingEntireAttachment,
                                                                       hasResolveAttachment, false,
                                                                       loadOverride,
                                                                       storeOverride)) {
				mtlColorAttDesc.clearColor = pixFmts->getMTLClearColor(clearValues[clrRPAttIdx], clrMVKRPAtt->getFormat());
			}
		}
	}

	// Populate the Metal depth and stencil attachments
	uint32_t dsRPAttIdx = _depthStencilAttachment.attachment;
	if (dsRPAttIdx != VK_ATTACHMENT_UNUSED) {
		MVKRenderPassAttachment* dsMVKRPAtt = &_renderPass->_attachments[dsRPAttIdx];
		MVKImageView* dsImage = framebuffer->getAttachment(dsRPAttIdx);
		MTLPixelFormat mtlDSFormat = dsImage->getMTLPixelFormat(0);

		if (pixFmts->isDepthFormat(mtlDSFormat)) {
			MTLRenderPassDepthAttachmentDescriptor* mtlDepthAttDesc = mtlRPDesc.depthAttachment;
			dsImage->populateMTLRenderPassAttachmentDescriptor(mtlDepthAttDesc);
			if (dsMVKRPAtt->populateMTLRenderPassAttachmentDescriptor(mtlDepthAttDesc, this,
                                                                      isRenderingEntireAttachment,
                                                                      false, false,
                                                                      loadOverride,
                                                                      storeOverride)) {
                mtlDepthAttDesc.clearDepth = pixFmts->getMTLClearDepthValue(clearValues[dsRPAttIdx]);
			}
		}
		if (pixFmts->isStencilFormat(mtlDSFormat)) {
			MTLRenderPassStencilAttachmentDescriptor* mtlStencilAttDesc = mtlRPDesc.stencilAttachment;
			dsImage->populateMTLRenderPassAttachmentDescriptor(mtlStencilAttDesc);
			if (dsMVKRPAtt->populateMTLRenderPassAttachmentDescriptor(mtlStencilAttDesc, this,
                                                                      isRenderingEntireAttachment,
                                                                      false, true,
                                                                      loadOverride,
                                                                      storeOverride)) {
				mtlStencilAttDesc.clearStencil = pixFmts->getMTLClearStencilValue(clearValues[dsRPAttIdx]);
			}
		}
	}

	_mtlDummyTex = nil;
	if (caUsedCnt == 0 && dsRPAttIdx == VK_ATTACHMENT_UNUSED) {
		// Add a dummy attachment so this passes validation.
		VkExtent2D fbExtent = framebuffer->getExtent2D();
		MTLTextureDescriptor* mtlTexDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat: MTLPixelFormatR8Unorm width: fbExtent.width height: fbExtent.height mipmapped: NO];
		if (framebuffer->getLayerCount() > 1) {
			mtlTexDesc.textureType = MTLTextureType2DArray;
			mtlTexDesc.arrayLength = framebuffer->getLayerCount();
		}
#if MVK_IOS
		if ([_renderPass->getMTLDevice() supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v3]) {
			mtlTexDesc.storageMode = MTLStorageModeMemoryless;
		} else {
			mtlTexDesc.storageMode = MTLStorageModePrivate;
		}
#else
		mtlTexDesc.storageMode = MTLStorageModePrivate;
#endif
		mtlTexDesc.usage = MTLTextureUsageRenderTarget;
		_mtlDummyTex = [_renderPass->getMTLDevice() newTextureWithDescriptor: mtlTexDesc];  // not retained
		[_mtlDummyTex setPurgeableState: MTLPurgeableStateVolatile];
		MTLRenderPassColorAttachmentDescriptor* mtlColorAttDesc = mtlRPDesc.colorAttachments[0];
		mtlColorAttDesc.texture = _mtlDummyTex;
		mtlColorAttDesc.level = 0;
		mtlColorAttDesc.slice = 0;
		mtlColorAttDesc.depthPlane = 0;
		mtlColorAttDesc.loadAction = MTLLoadActionDontCare;
		mtlColorAttDesc.storeAction = MTLStoreActionDontCare;
	}
}

void MVKRenderSubpass::populateClearAttachments(MVKClearAttachments& clearAtts,
												const MVKArrayRef<VkClearValue>& clearValues) {
	VkClearAttachment cAtt;

	uint32_t attIdx;
	uint32_t caCnt = getColorAttachmentCount();
	for (uint32_t caIdx = 0; caIdx < caCnt; caIdx++) {
		attIdx = _colorAttachments[caIdx].attachment;
		if ((attIdx != VK_ATTACHMENT_UNUSED) && _renderPass->_attachments[attIdx].shouldUseClearAttachment(this)) {
			cAtt.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
			cAtt.colorAttachment = caIdx;
			cAtt.clearValue = clearValues[attIdx];
			clearAtts.push_back(cAtt);
		}
	}

	attIdx = _depthStencilAttachment.attachment;
	if ((attIdx != VK_ATTACHMENT_UNUSED) && _renderPass->_attachments[attIdx].shouldUseClearAttachment(this)) {
		cAtt.aspectMask = 0;
		cAtt.colorAttachment = 0;
		cAtt.clearValue = clearValues[attIdx];

		MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();
		MTLPixelFormat mtlDSFmt = _renderPass->getPixelFormats()->getMTLPixelFormat(getDepthStencilFormat());
		if (pixFmts->isDepthFormat(mtlDSFmt)) { cAtt.aspectMask |= VK_IMAGE_ASPECT_DEPTH_BIT; }
		if (pixFmts->isStencilFormat(mtlDSFmt)) { cAtt.aspectMask |= VK_IMAGE_ASPECT_STENCIL_BIT; }
		if (cAtt.aspectMask) { clearAtts.push_back(cAtt); }
	}
}

// Returns the format capabilities required by this render subpass.
// It is possible for a subpass to use a single framebuffer attachment for multiple purposes.
// For example, a subpass may use a color or depth attachment as an input attachment as well.
// So, accumulate the capabilities from all possible attachments, just to be safe.
MVKMTLFmtCaps MVKRenderSubpass::getRequiredFormatCapabilitiesForAttachmentAt(uint32_t rpAttIdx) {
	MVKMTLFmtCaps caps = kMVKMTLFmtCapsNone;

	for (auto& att : _inputAttachments) {
		if (att.attachment == rpAttIdx) {
			mvkEnableFlags(caps, kMVKMTLFmtCapsRead);
			break;
		}
	}
	for (auto& att : _colorAttachments) {
		if (att.attachment == rpAttIdx) {
			mvkEnableFlags(caps, kMVKMTLFmtCapsColorAtt);
			break;
		}
	}
	for (auto& att : _resolveAttachments) {
		if (att.attachment == rpAttIdx) {
			mvkEnableFlags(caps, kMVKMTLFmtCapsResolve);
			break;
		}
	}
	if (_depthStencilAttachment.attachment == rpAttIdx) { mvkEnableFlags(caps, kMVKMTLFmtCapsDSAtt); }

	return caps;
}

MVKRenderSubpass::MVKRenderSubpass(MVKRenderPass* renderPass,
								   const VkSubpassDescription* pCreateInfo) {
	_renderPass = renderPass;
	_subpassIndex = (uint32_t)_renderPass->_subpasses.size();

	// Add attachments
	_inputAttachments.reserve(pCreateInfo->inputAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->inputAttachmentCount; i++) {
		_inputAttachments.push_back(pCreateInfo->pInputAttachments[i]);
	}

	_colorAttachments.reserve(pCreateInfo->colorAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->colorAttachmentCount; i++) {
		_colorAttachments.push_back(pCreateInfo->pColorAttachments[i]);
	}

	if (pCreateInfo->pResolveAttachments) {
		_resolveAttachments.reserve(pCreateInfo->colorAttachmentCount);
		for (uint32_t i = 0; i < pCreateInfo->colorAttachmentCount; i++) {
			_resolveAttachments.push_back(pCreateInfo->pResolveAttachments[i]);
		}
	}

	if (pCreateInfo->pDepthStencilAttachment) {
		_depthStencilAttachment = *pCreateInfo->pDepthStencilAttachment;
	} else {
		_depthStencilAttachment.attachment = VK_ATTACHMENT_UNUSED;
	}

	_preserveAttachments.reserve(pCreateInfo->preserveAttachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->preserveAttachmentCount; i++) {
		_preserveAttachments.push_back(pCreateInfo->pPreserveAttachments[i]);
	}
}


#pragma mark -
#pragma mark MVKRenderPassAttachment

MVKVulkanAPIObject* MVKRenderPassAttachment::getVulkanAPIObject() { return _renderPass->getVulkanAPIObject(); };

VkFormat MVKRenderPassAttachment::getFormat() { return _info.format; }

VkSampleCountFlagBits MVKRenderPassAttachment::getSampleCount() { return _info.samples; }

bool MVKRenderPassAttachment::populateMTLRenderPassAttachmentDescriptor(MTLRenderPassAttachmentDescriptor* mtlAttDesc,
                                                                        MVKRenderSubpass* subpass,
                                                                        bool isRenderingEntireAttachment,
                                                                        bool hasResolveAttachment,
                                                                        bool isStencil,
                                                                        bool loadOverride,
                                                                        bool storeOverride) {

    bool willClear = false;		// Assume the attachment won't be cleared

    // Only allow clearing of entire attachment if we're actually rendering to the entire
    // attachment AND we're in the first subpass.
    if ( loadOverride ) {
        mtlAttDesc.loadAction = MTLLoadActionLoad;
    } else if ( isRenderingEntireAttachment && (subpass->_subpassIndex == _firstUseSubpassIdx) ) {
        VkAttachmentLoadOp loadOp = isStencil ? _info.stencilLoadOp : _info.loadOp;
        mtlAttDesc.loadAction = mvkMTLLoadActionFromVkAttachmentLoadOp(loadOp);
        willClear = (loadOp == VK_ATTACHMENT_LOAD_OP_CLEAR);
    } else {
        mtlAttDesc.loadAction = MTLLoadActionLoad;
    }

    // If a resolve attachment exists, this attachment must resolve once complete.
    // Otherwise only allow the attachment to be discarded if we're actually rendering
    // to the entire attachment and we're in the last subpass.
    if (hasResolveAttachment && !_renderPass->getDevice()->getPhysicalDevice()->getMetalFeatures()->combinedStoreResolveAction) {
        mtlAttDesc.storeAction = MTLStoreActionMultisampleResolve;
    } else if ( storeOverride ) {
        mtlAttDesc.storeAction = hasResolveAttachment ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionStore;
    } else if ( isRenderingEntireAttachment && (subpass->_subpassIndex == _lastUseSubpassIdx) ) {
        VkAttachmentStoreOp storeOp = isStencil ? _info.stencilStoreOp : _info.storeOp;
        mtlAttDesc.storeAction = mvkMTLStoreActionFromVkAttachmentStoreOp(storeOp, hasResolveAttachment);
    } else {
        mtlAttDesc.storeAction = hasResolveAttachment ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionStore;
    }
    return willClear;
}

bool MVKRenderPassAttachment::shouldUseClearAttachment(MVKRenderSubpass* subpass) {

	// If the subpass is not the first subpass to use this attachment, don't clear this attachment
	if (subpass->_subpassIndex != _firstUseSubpassIdx) { return false; }

	return (_info.loadOp == VK_ATTACHMENT_LOAD_OP_CLEAR);
}

MVKRenderPassAttachment::MVKRenderPassAttachment(MVKRenderPass* renderPass,
												 const VkAttachmentDescription* pCreateInfo) {
	_info = *pCreateInfo;
	_renderPass = renderPass;
	_attachmentIndex = uint32_t(_renderPass->_attachments.size());

	// Validate pixel format is supported
	MVKPixelFormats* pixFmts = _renderPass->getPixelFormats();
	if ( !pixFmts->isSupportedOrSubstitutable(_info.format) ) {
		_renderPass->setConfigurationResult(reportError(VK_ERROR_FORMAT_NOT_SUPPORTED, "vkCreateRenderPass(): Attachment format %s is not supported on this device.", _renderPass->getPixelFormats()->getName(_info.format)));
	}

	// Determine the indices of the first and last render subpasses to use this attachment.
	_firstUseSubpassIdx = kMVKUndefinedLargeUInt32;
	_lastUseSubpassIdx = 0;
	for (auto& subPass : _renderPass->_subpasses) {
		// If it uses this attachment, the subpass will identify required format capabilities.
		MVKMTLFmtCaps reqCaps = subPass.getRequiredFormatCapabilitiesForAttachmentAt(_attachmentIndex);
		if (reqCaps) {
			uint32_t spIdx = subPass._subpassIndex;
			_firstUseSubpassIdx = min(spIdx, _firstUseSubpassIdx);
			_lastUseSubpassIdx = max(spIdx, _lastUseSubpassIdx);

			// Validate that the attachment pixel format supports the capabilities required by the subpass.
			// Use MTLPixelFormat to look up capabilities to permit Metal format substitution.
			if ( !mvkAreAllFlagsEnabled(pixFmts->getCapabilities(pixFmts->getMTLPixelFormat(_info.format)), reqCaps) ) {
				_renderPass->setConfigurationResult(reportError(VK_ERROR_FORMAT_NOT_SUPPORTED, "vkCreateRenderPass(): Attachment format %s on this device does not support the VkFormat attachment capabilities required by the subpass at index %d.", _renderPass->getPixelFormats()->getName(_info.format), spIdx));
			}
		}
	}
}


#pragma mark -
#pragma mark MVKRenderPass

VkExtent2D MVKRenderPass::getRenderAreaGranularity() { return { 1, 1 }; }

MVKRenderSubpass* MVKRenderPass::getSubpass(uint32_t subpassIndex) { return &_subpasses[subpassIndex]; }

MVKRenderPass::MVKRenderPass(MVKDevice* device,
							 const VkRenderPassCreateInfo* pCreateInfo) : MVKVulkanAPIDeviceObject(device) {

    // Add subpasses and dependencies first
	_subpasses.reserve(pCreateInfo->subpassCount);
	for (uint32_t i = 0; i < pCreateInfo->subpassCount; i++) {
		_subpasses.emplace_back(this, &pCreateInfo->pSubpasses[i]);
	}
	_subpassDependencies.reserve(pCreateInfo->dependencyCount);
	for (uint32_t i = 0; i < pCreateInfo->dependencyCount; i++) {
		_subpassDependencies.push_back(pCreateInfo->pDependencies[i]);
	}

	// Add attachments after subpasses, so each attachment can link to subpasses
	_attachments.reserve(pCreateInfo->attachmentCount);
	for (uint32_t i = 0; i < pCreateInfo->attachmentCount; i++) {
		_attachments.emplace_back(this, &pCreateInfo->pAttachments[i]);
	}
}


