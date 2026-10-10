//go:build darwin && cgo

package config

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>

// Test seam uses the exact CoreFoundation constructor used by all item queries.
static char *bridgeAccountRoundTrip(const char *account) {
 CFStringRef a=CFStringCreateWithCString(NULL,account,kCFStringEncodingUTF8);
 if(a==NULL) return NULL;
 CFIndex length=CFStringGetMaximumSizeForEncoding(CFStringGetLength(a),kCFStringEncodingUTF8)+1;
 char *result=malloc(length);
 if(result!=NULL && !CFStringGetCString(a,result,length,kCFStringEncodingUTF8)){free(result);result=NULL;}
 CFRelease(a);return result;
}
static OSStatus bridgeGet(const char *service, const char *account, char **result, size_t *length) {
 CFStringRef s=CFStringCreateWithCString(NULL,service,kCFStringEncodingUTF8);
 CFStringRef a=CFStringCreateWithCString(NULL,account,kCFStringEncodingUTF8);
 const void *keys[]={kSecClass,kSecAttrService,kSecAttrAccount,kSecReturnData,kSecMatchLimit};
 const void *values[]={kSecClassGenericPassword,s,a,kCFBooleanTrue,kSecMatchLimitOne};
 CFDictionaryRef query=CFDictionaryCreate(NULL,keys,values,5,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 SecKeychainSetUserInteractionAllowed(false);CFTypeRef value=NULL;OSStatus status=SecItemCopyMatching(query,&value);
 if(status==errSecSuccess){CFDataRef data=(CFDataRef)value;*length=CFDataGetLength(data);*result=malloc(*length);memcpy(*result,CFDataGetBytePtr(data),*length);CFRelease(value);}
 CFRelease(query);CFRelease(a);CFRelease(s);return status;
}
static OSStatus bridgeSet(const char *service,const char *account,const char *value,size_t length) {
 CFStringRef s=CFStringCreateWithCString(NULL,service,kCFStringEncodingUTF8);CFStringRef a=CFStringCreateWithCString(NULL,account,kCFStringEncodingUTF8);
 const void *keys[]={kSecClass,kSecAttrService,kSecAttrAccount};const void *values[]={kSecClassGenericPassword,s,a};
 CFDictionaryRef query=CFDictionaryCreate(NULL,keys,values,3,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 CFDataRef data=CFDataCreate(NULL,(const UInt8*)value,length);
 const void *updateKeys[]={kSecValueData};const void *updateValues[]={data};
 CFDictionaryRef update=CFDictionaryCreate(NULL,updateKeys,updateValues,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 SecKeychainSetUserInteractionAllowed(false);OSStatus status=SecItemUpdate(query,update);
 if(status==errSecItemNotFound){CFMutableDictionaryRef insertion=CFDictionaryCreateMutableCopy(NULL,0,query);CFDictionarySetValue(insertion,kSecValueData,data);status=SecItemAdd(insertion,NULL);CFRelease(insertion);}
 CFRelease(update);CFRelease(data);CFRelease(query);CFRelease(a);CFRelease(s);return status;
}
static OSStatus bridgeDelete(const char *service,const char *account) {
 CFStringRef s=CFStringCreateWithCString(NULL,service,kCFStringEncodingUTF8);CFStringRef a=CFStringCreateWithCString(NULL,account,kCFStringEncodingUTF8);
 const void *keys[]={kSecClass,kSecAttrService,kSecAttrAccount};const void *values[]={kSecClassGenericPassword,s,a};
 CFDictionaryRef query=CFDictionaryCreate(NULL,keys,values,3,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 OSStatus status=SecItemDelete(query);CFRelease(query);CFRelease(a);CFRelease(s);return status;
}
*/
import "C"
import (
	"errors"
	"fmt"
	"unsafe"
)

var errSecretMissing = errors.New("credential missing")

func SecretMissing(err error) bool { return errors.Is(err, errSecretMissing) }
func statusError(status C.OSStatus) error {
	if status == C.errSecSuccess {
		return nil
	}
	if status == C.errSecItemNotFound {
		return errSecretMissing
	}
	return fmt.Errorf("credential_unavailable: Keychain status %d", int(status))
}
func (store KeychainStore) Get(key string) (string, error) {
	encoded, err := store.account(key)
	if err != nil {
		return "", err
	}
	service := C.CString(store.service())
	account := C.CString(encoded)
	defer C.free(unsafe.Pointer(service))
	defer C.free(unsafe.Pointer(account))
	var raw *C.char
	var size C.size_t
	status := C.bridgeGet(service, account, &raw, &size)
	err = statusError(status)
	if err != nil {
		return "", err
	}
	defer C.free(unsafe.Pointer(raw))
	return C.GoStringN(raw, C.int(size)), nil
}
func (store KeychainStore) Set(key, value string) error {
	encoded, err := store.account(key)
	if err != nil {
		return err
	}
	service := C.CString(store.service())
	account := C.CString(encoded)
	raw := C.CString(value)
	defer C.free(unsafe.Pointer(service))
	defer C.free(unsafe.Pointer(account))
	defer C.free(unsafe.Pointer(raw))
	return statusError(C.bridgeSet(service, account, raw, C.size_t(len(value))))
}
func (store KeychainStore) Delete(key string) error {
	encoded, err := store.account(key)
	if err != nil {
		return err
	}
	service := C.CString(store.service())
	account := C.CString(encoded)
	defer C.free(unsafe.Pointer(service))
	defer C.free(unsafe.Pointer(account))
	status := C.bridgeDelete(service, account)
	if status == C.errSecItemNotFound {
		return nil
	}
	return statusError(status)
}

// keychainAccountCFString exercises account serialization without a Keychain item
// or user prompt. Darwin regression tests use the actual C/CFString boundary.
func (store KeychainStore) keychainAccountCFString(key string) (string, error) {
	encoded, err := store.account(key)
	if err != nil {
		return "", err
	}
	account := C.CString(encoded)
	defer C.free(unsafe.Pointer(account))
	result := C.bridgeAccountRoundTrip(account)
	if result == nil {
		return "", fmt.Errorf("Keychain account encoding failed")
	}
	defer C.free(unsafe.Pointer(result))
	return C.GoString(result), nil
}
