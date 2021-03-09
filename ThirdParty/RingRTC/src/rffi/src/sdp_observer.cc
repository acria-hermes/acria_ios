/*
 * Copyright 2019-2021 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

#include "rffi/api/sdp_observer_intf.h"
#include "rffi/src/sdp_observer.h"
#include <regex>

namespace webrtc {
namespace rffi {

CreateSessionDescriptionObserverRffi::CreateSessionDescriptionObserverRffi(const rust_object                                csd_observer,
                                                                           const CreateSessionDescriptionObserverCallbacks* csd_observer_cbs)
  : csd_observer_(csd_observer), csd_observer_cbs_(*csd_observer_cbs)
{
  RTC_LOG(LS_INFO) << "CreateSessionDescriptionObserverRffi:ctor(): " << this->csd_observer_;
}

CreateSessionDescriptionObserverRffi::~CreateSessionDescriptionObserverRffi() {
  RTC_LOG(LS_INFO) << "CreateSessionDescriptionObserverRffi:dtor(): " << this->csd_observer_;
}

void CreateSessionDescriptionObserverRffi::OnSuccess(SessionDescriptionInterface* session_description) {
  // OnSuccess transfers ownership of the description
  RTC_LOG(LS_INFO) << "CreateSessionDescriptionObserverRffi:OnSuccess(): ";

  // TODO tweak the response a little
  std::string sdp;
  if (session_description->ToString(&sdp)) {
    sdp = std::regex_replace(sdp, std::regex("(a=fmtp:111 ((?!cbr=).)*)\r?\n"), "$1;cbr=1\r\n");
    sdp = std::regex_replace(sdp, std::regex(".+urn:ietf:params:rtp-hdrext:ssrc-audio-level.*\r?\n"), "");

    std::unique_ptr<SessionDescriptionInterface> session_description2 = CreateSessionDescription(session_description->GetType(), sdp);
    delete session_description;
    this->csd_observer_cbs_.onSuccess(this->csd_observer_, session_description2.release());
  } else {
    RTC_LOG(LS_ERROR) << "Unable to convert SessionDescriptionInterface to std::string";
  }
}

void CreateSessionDescriptionObserverRffi::OnFailure(RTCError error) {
  RTC_LOG(LS_INFO) << "CreateSessionDescriptionObserverRffi:OnFailure(): ";
  this->csd_observer_cbs_.onFailure(this->csd_observer_, error.message(), static_cast<int32_t>(error.type()));
}

RUSTEXPORT CreateSessionDescriptionObserverRffi*
Rust_createCreateSessionDescriptionObserver(const rust_object                                csd_observer,
                                            const CreateSessionDescriptionObserverCallbacks* csd_observer_cbs) {
  return new rtc::RefCountedObject<CreateSessionDescriptionObserverRffi>(csd_observer, csd_observer_cbs);
}

SetSessionDescriptionObserverRffi::SetSessionDescriptionObserverRffi(const rust_object                             ssd_observer,
                                                                     const SetSessionDescriptionObserverCallbacks* ssd_observer_cbs)
  : ssd_observer_(ssd_observer), ssd_observer_cbs_(*ssd_observer_cbs)
{
  RTC_LOG(LS_INFO) << "SetSessionDescriptionObserverRffi:ctor(): " << this->ssd_observer_;
}

SetSessionDescriptionObserverRffi::~SetSessionDescriptionObserverRffi() {
  RTC_LOG(LS_INFO) << "SetSessionDescriptionObserverRffi:dtor(): " << this->ssd_observer_;
}

void SetSessionDescriptionObserverRffi::OnSuccess() {
  RTC_LOG(LS_INFO) << "SetSessionDescriptionObserverRffi:OnSuccess(): ";
  this->ssd_observer_cbs_.onSuccess(this->ssd_observer_);
}

void SetSessionDescriptionObserverRffi::OnFailure(RTCError error) {
  RTC_LOG(LS_INFO) << "SetSessionDescriptionObserverRffi:OnFailure(): ";
  this->ssd_observer_cbs_.onFailure(this->ssd_observer_, error.message(), static_cast<int32_t>(error.type()));
}

RUSTEXPORT SetSessionDescriptionObserverRffi*
Rust_createSetSessionDescriptionObserver(const rust_object                             ssd_observer,
                                         const SetSessionDescriptionObserverCallbacks* ssd_observer_cbs) {
  return new rtc::RefCountedObject<SetSessionDescriptionObserverRffi>(ssd_observer, ssd_observer_cbs);
}

} // namespace rffi
} // namespace webrtc
