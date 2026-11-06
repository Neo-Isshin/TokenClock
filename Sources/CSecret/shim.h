#ifndef TC_SECRET_SHIM_H
#define TC_SECRET_SHIM_H
#include <libsecret/secret.h>
#include <openssl/evp.h>
#include <openssl/crypto.h>
#include <string.h>

/* OSCrypt Linux v10/v11: PBKDF2-HMAC-SHA1, one iteration, AES-128-CBC.
   Only the requested application's existing secret is read; nothing is stored. */
static inline char *tc_linux_oscrypt_decode(const unsigned char *bytes,int length,const char *password){
    if(!bytes||length<=3||length>4194304||!password||strlen(password)>16384)return NULL;
    if(memcmp(bytes,"v10",3)!=0&&memcmp(bytes,"v11",3)!=0)return NULL;
    unsigned char key[16],iv[16];memset(iv,0x20,16);
    if(!PKCS5_PBKDF2_HMAC_SHA1(password,-1,(const unsigned char*)"saltysalt",9,1,16,key))return NULL;
    EVP_CIPHER_CTX *ctx=EVP_CIPHER_CTX_new();if(!ctx){OPENSSL_cleanse(key,16);return NULL;}
    unsigned char *out=g_malloc((gsize)length+17);int a=0,b=0;
    int ok=EVP_DecryptInit_ex(ctx,EVP_aes_128_cbc(),NULL,key,iv)&&EVP_DecryptUpdate(ctx,out,&a,bytes+3,length-3)&&EVP_DecryptFinal_ex(ctx,out+a,&b);
    EVP_CIPHER_CTX_free(ctx);OPENSSL_cleanse(key,16);
    if(!ok||!g_utf8_validate((const char*)out,a+b,NULL)){OPENSSL_cleanse(out,length+17);g_free(out);return NULL;}
    out[a+b]=0;return (char*)out;
}
typedef struct{GCancellable *cancel;gint done;gint refs;gulong delay;} TCSecretDeadline;
static inline void tc_secret_deadline_release(TCSecretDeadline *d){if(g_atomic_int_dec_and_test(&d->refs)){g_object_unref(d->cancel);g_free(d);}}
static inline gpointer tc_secret_deadline(gpointer pointer){
    TCSecretDeadline *d=pointer;g_usleep(d->delay);if(!g_atomic_int_get(&d->done))g_cancellable_cancel(d->cancel);tc_secret_deadline_release(d);return NULL;
}
static inline char *tc_linux_grok_storage_password(int allow_prompt,int *authorization){
    *authorization=0;
    if(!g_getenv("DBUS_SESSION_BUS_ADDRESS"))return NULL;
    GCancellable *cancel=g_cancellable_new();TCSecretDeadline *d=g_new0(TCSecretDeadline,1);d->cancel=g_object_ref(cancel);d->refs=2;d->delay=allow_prompt?90000000:2000000;
    GThread *timer=g_thread_new("tc-secret-timeout",tc_secret_deadline,d);g_thread_unref(timer);
    GError *error=NULL;char *password=NULL;
    SecretService *service=secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION,cancel,&error);
    if(!service)goto done;
    const SecretSchema schema={"chrome_libsecret_os_crypt_password_v2",SECRET_SCHEMA_DONT_MATCH_NAME,{{"application",SECRET_SCHEMA_ATTRIBUTE_STRING},{NULL,0}}};
    const char *apps[]={"grok-bot","Grok Bot","grokbot"};
    for(int i=0;i<3&&!password&&!g_cancellable_is_cancelled(cancel);i++){
        GHashTable *attributes=secret_attributes_build(&schema,"application",apps[i],NULL);
        GList *items=secret_service_search_sync(service,&schema,attributes,SECRET_SEARCH_ALL,cancel,&error);g_hash_table_unref(attributes);g_clear_error(&error);
        for(GList *it=items;it&&!password;it=it->next){
            SecretItem *item=SECRET_ITEM(it->data);char *label=secret_item_get_label(item);
            int matches=label&&(strcmp(label,"Grok Bot Safe Storage")==0||strcmp(label,"grok-bot Safe Storage")==0);g_free(label);if(!matches)continue;
            if(secret_item_get_locked(item)){
                *authorization=1;if(!allow_prompt)continue;
                GList one={item,NULL,NULL},*unlocked=NULL;secret_service_unlock_sync(service,&one,cancel,&unlocked,&error);g_list_free_full(unlocked,g_object_unref);g_clear_error(&error);
            }
            if(secret_item_get_locked(item))continue;
            if(secret_item_load_secret_sync(item,cancel,&error)){
                SecretValue *value=secret_item_get_secret(item);if(value){gsize size=0;const char *text=secret_value_get(value,&size);if(text&&size>0&&size<=16384&&g_utf8_validate(text,size,NULL))password=g_strndup(text,size);secret_value_unref(value);}
            }g_clear_error(&error);
        }g_list_free_full(items,g_object_unref);
    }g_object_unref(service);
done:
    g_clear_error(&error);g_atomic_int_set(&d->done,1);tc_secret_deadline_release(d);g_object_unref(cancel);return password;
}
static inline void tc_secret_string_free(char *value){if(value){OPENSSL_cleanse(value,strlen(value));g_free(value);}}
#endif
