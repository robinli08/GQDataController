//
//  GQDataController.m
//  GQDataController
//
//  Created by 钱国强 on 14-5-25.
//  Copyright (c) 2014年 Qian GuoQiang. All rights reserved.
//

#import "GQDataController.h"
#import "GQDefaultAdapter.h"

#if DEBUG
#import "GQHTTPStub.h"
#endif

NSString * const GQDataControllerErrorDomain = @"GQDataControllerErrorDomain";

const NSInteger GQDataControllerErrorInvalidObject = 1;

NSString * const GQResponseObjectKey = @"GQResponseObjectKey";

@interface GQDataController ()

@property (nonatomic, strong) AFHTTPSessionManager *httpSessionManager;

/**
 *  当前请求的Task
 */
@property (nonatomic, strong) NSURLSessionDataTask *URLSessionDataTask;

/**
 *  请求参数备份
 */
@property (nonatomic, copy) NSDictionary *requestParams;

/**
 *  接口请求重试计数
 */
@property (nonatomic) NSUInteger requestCount;


@end

@implementation GQDataController

- (id)copyWithZone:(NSZone *)zone
{
    GQDataController *copy = [[[self class] allocWithZone:zone] initWithDelegate:self.delegate];
    
    copy.requestSuccessBlock = self.requestSuccessBlock;
    copy.requestFailureBlock = self.requestFailureBlock;
    copy.requestCompletedBlock = self.requestCompletedBlock;
    copy.logBlock = self.logBlock;
    
    return copy;
}

+ (instancetype)sharedDataController
{
    static dispatch_once_t onceToken;
    static NSMutableDictionary *sharedInstances = nil;
    static NSLock *sharedLock = nil;
    
    dispatch_once(&onceToken, ^{
        sharedInstances = [NSMutableDictionary dictionary];
        sharedLock = [[NSLock alloc] init];
    });
    
    NSString *keyName = NSStringFromClass([self class]);
    GQDataController *aController = nil;
    
    if ([sharedLock tryLock]) {
        aController = [sharedInstances objectForKey:keyName];
        
        if (aController == nil) {
            aController = [[self alloc] init];
            
            [sharedInstances setObject:aController
                                forKey:keyName];
        }
        
        [sharedLock unlock];
    }
    
    return aController;
}

- (NSURLSessionConfiguration *)makeSessionConfiguration
{
    static dispatch_once_t onceToken;
    static NSURLSessionConfiguration *_sessionConfiguration = nil;
    
    dispatch_once(&onceToken, ^{
        _sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
        
        NSMutableArray * protocolsArray = [_sessionConfiguration.protocolClasses mutableCopy];
        
        [protocolsArray insertObject:[GQSQLiteProtocol class] atIndex:0];
#if DEBUG
        [protocolsArray insertObject:[GQHTTPStub class] atIndex:0];
#endif
        _sessionConfiguration.protocolClasses = protocolsArray;
    });
    
    return _sessionConfiguration;
}

- (instancetype)init
{
    self = [super init];
    
    if (self) {
        _httpSessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:[self makeSessionConfiguration]];
        
        [(AFJSONResponseSerializer *)[_httpSessionManager responseSerializer] setRemovesKeysWithNullValues:YES];
        
        _cellIdentifier = NSStringFromClass([self class]);
    }
    
    return self;
}

- (instancetype)initWithDelegate:(id <GQDataControllerDelegate>)aDelegate
{
    self = [self init];
    
    if (self) {
        self.delegate = aDelegate;
    }
    
    return self;
}

+ (instancetype)dataControllerWithSuccessBlock:(nullable GQRequestSuccessBlock)success
                                  failureBlock:(nullable GQRequestFailureBlock)failure
                                completedBlock:(nullable GQRequestCompletedBlock)complated
{
    GQDataController *newInstance = [[self alloc] initWithSuccessBlock:success failureBlock:failure completedBlock:complated];
    
    return newInstance;
}

- (instancetype)initWithSuccessBlock:(nullable GQRequestSuccessBlock)success failureBlock:(nullable GQRequestFailureBlock)failure completedBlock:(nullable GQRequestCompletedBlock)complated
{
    self = [self init];
    
    if (self) {
        self.requestSuccessBlock = success;
        self.requestFailureBlock = failure;
        self.requestCompletedBlock = complated;
    }
    
    return self;
}


#pragma mark - Public 

- (void)request
{
    [self requestWithParams:nil];
}

- (void)requestWithParams:(NSDictionary *)params
{
    [self requestWithParams:params isRetry:NO];
}

- (void)requestWithParams:(NSDictionary *)params
                  success:(GQRequestSuccessBlock)success
                  failure:(GQRequestFailureBlock)failure
{
    self.requestSuccessBlock = success;
    
    self.requestFailureBlock = failure;
    
    self.requestCompletedBlock = nil;
    
    [self requestWithParams:params isRetry:NO];
}

- (void)requestMore
{
    NSString *pageName = [self pageParameterName];
    
    NSMutableDictionary *newParams = [self.requestParams mutableCopy];
    
    if (newParams == nil) {
        newParams = [NSMutableDictionary dictionary];
    }
    
    if (pageName) {
        if ([newParams objectForKey:pageName]) {
            newParams[pageName] = @([[newParams objectForKey:pageName] integerValue] + 1);
        } else {
            newParams[pageName] = @(1);
        }
    }
    
    // 默认插入模式
    self.modelObjectListUpdatePolicy = GQModelObjectListUpdatePolicyInsert;
    
    [self requestWithParams:newParams];
}

- (void)cancelRequest
{
    if (self.URLSessionDataTask) {
        [self.URLSessionDataTask cancel];
        self.URLSessionDataTask = nil;
        
        if ([self.delegate respondsToSelector:@selector(dataControllerDidCancelLoading:)]) {
            [self.delegate dataControllerDidCancelLoading:self];
        }
    }
}

#pragma mark - Custom Method


- (void)requestOpertaionSuccess:(NSURLSessionDataTask *)task responseObject:(id)responseObject
{
    if ([self isValidWithJSONObject:responseObject]) {
        
        [self handleWithJSONObject:responseObject];
        
        if ([self.delegate respondsToSelector:@selector(dataControllerDidFinishLoading:)]) {
            [self.delegate dataControllerDidFinishLoading:self];
        }
        
        if (self.requestSuccessBlock) {
            self.requestSuccessBlock(self);
        }
        
        if (self.requestCompletedBlock) {
            self.requestCompletedBlock(self);
        }
    } else {
        NSError *error = nil;
        
        if (responseObject) {
            error = [NSError errorWithDomain:GQDataControllerErrorDomain
                                        code:GQDataControllerErrorInvalidObject
                                    userInfo:@{ GQResponseObjectKey : responseObject }];
        }
        
        [self requestOperationFailure:task error:error];
    }
}

- (void)requestOperationFailure:(NSURLSessionDataTask *)task error:(NSError *)error
{
    [self logWithObject:[error localizedDescription]];
    
    if ([self.delegate respondsToSelector:@selector(dataController:didFailWithError:)]) {
        [self.delegate dataController:self
                     didFailWithError:error];
    }
    
    if (self.requestFailureBlock) {
        self.requestFailureBlock(self, error);
    }
    
    if (self.requestCompletedBlock) {
        self.requestCompletedBlock(self);
    }
}

- (NSString *)requestMethod
{
    return @"GET";
}

- (NSArray<NSString *> *)requestURLStrings
{
    return nil;
}

- (NSString *)pageParameterName
{
    return @"p";
}

- (BOOL)isValidWithJSONObject:(id)object
{
    return YES;
}

- (void)handleWithJSONObject:(id)object
{
    [self handleModelObjectWithJSONObject:object];
    
    [self handleModelObjectListWithJSONObject:object];
}

- (Class)modelAdapterClass
{
    return [GQDefaultAdapter class];
}

- (Class)modelObjectClass
{
    return Nil;
}

- (Class)modelObjectListClass
{
    return [self modelObjectClass];
}

- (NSString *)modelObjectKeyPath
{
    return nil;
}

- (NSString *)modelObjectListKeyPath
{
    return [self modelObjectKeyPath];
}

#pragma mark - Private


- (void)requestWithParams:(NSDictionary *)params isRetry:(BOOL)retry
{
    if (retry == NO) {
        // 如果不是重试，则重置状态
        [self cancelRequest];
        
        self.requestParams = params;
        self.requestCount = 0;
    }
    
    // 1. 生成URL
    NSString *urlString = nil;
    
    NSArray *URLs = [self requestURLStrings];
    
    NSAssert([URLs isKindOfClass:[NSArray class]], @"Must be a NSArray");
    
    if ([URLs count] < 1) {
        return;
    }
    
    urlString = [URLs[self.requestCount] stringByBindSQLiteWithParams:params];
    
#if DEBUG
    
    NSString *localJSONName = [NSString stringWithFormat:@"%@.json", NSStringFromClass([self class])];
    
    NSString *localJSONPath = [[NSBundle mainBundle] pathForResource:[localJSONName stringByDeletingPathExtension]
                                                              ofType:[localJSONName pathExtension]];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:localJSONPath]) {
        
        [self.httpSessionManager.requestSerializer setValue:localJSONPath
                                         forHTTPHeaderField:@"X-GQHTTPStub"];
    } else {
        [self.httpSessionManager.requestSerializer setValue:@"nil"
                                         forHTTPHeaderField:@"X-GQHTTPStub"];
    }
    
#endif
    
    // 2. 生成request
    NSString *method = [self requestMethod];
    
    __weak __typeof(self)weakSelf = self;
    
    void (^successBlock)(NSURLSessionDataTask *, id) = ^(NSURLSessionDataTask *task, id responseObject){
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        
        [strongSelf requestOpertaionSuccess:task
                             responseObject:responseObject];
        
        strongSelf.requestCount = 0;
    };
    
    void (^failureBlock)(NSURLSessionDataTask *, NSError *) = ^(NSURLSessionDataTask *task, NSError *error){
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        
        if (strongSelf.requestCount + 1 < [[strongSelf requestURLStrings] count]) {
            // 开始重试
            strongSelf.requestCount++;
            
            [strongSelf requestWithParams:strongSelf.requestParams
                                  isRetry:YES];
        } else {
            [strongSelf requestOperationFailure:task
                                          error:error];
        }
    };
    
    if ([self.delegate respondsToSelector:@selector(dataControllerWillStartLoading:)]) {
        [self.delegate dataControllerWillStartLoading:self];
    }
    
    if ([method isEqualToString:@"GET"]) {
        
        self.URLSessionDataTask = [self.httpSessionManager GET:urlString
                                                    parameters:params
                                                      progress:nil
                                                       success:successBlock
                                                       failure:failureBlock];
        
    } else if ([method isEqualToString:@"POST"]) {
        
        self.URLSessionDataTask = [self.httpSessionManager POST:urlString
                                                     parameters:params
                                                       progress:nil
                                                        success:successBlock
                                                        failure:failureBlock];
        
    } else if ([method isEqualToString:@"PUT"]) {
        
        self.URLSessionDataTask = [self.httpSessionManager PUT:urlString
                                                    parameters:params
                                                       success:successBlock
                                                       failure:failureBlock];
        
    } else if ([method isEqualToString:@"PATCH"]) {
        
        self.URLSessionDataTask = [self.httpSessionManager PATCH:urlString
                                                      parameters:params
                                                         success:successBlock
                                                         failure:failureBlock];
        
    } else if ([method isEqualToString:@"DELETE"]) {
        
        self.URLSessionDataTask = [self.httpSessionManager DELETE:urlString
                                                       parameters:params
                                                          success:successBlock
                                                          failure:failureBlock];
        
    }
    
    [self.URLSessionDataTask resume];
    
    [self logWithObject:self.URLSessionDataTask.currentRequest];
}

- (void)logWithObject:(id)object
{
    if (self.logBlock) {
        self.logBlock(object);
    } else {
        NSString *fullLog = [NSString stringWithFormat:@"GQDataController: %@", object];
        
        NSLog(@"%@", fullLog);
    }
}

- (void)handleModelObjectWithJSONObject:(id)object
{
    // 处理mantleObjectKeyPath
    NSString *objectKeyPath = [self modelObjectKeyPath];
    
    id mantleObjectJSON = object;
    
    if (objectKeyPath) { // 允许自定义转换的JSON节点
        mantleObjectJSON = [object valueForKeyPath:objectKeyPath];
    }
    
    if ([mantleObjectJSON isKindOfClass:[NSDictionary class]]) {
        
        [self handleModelObjectWithDictionary:mantleObjectJSON];
    }
}

- (void)handleModelObjectListWithJSONObject:(id)object
{
    // 处理mantleObjectListKeyPath
    NSString *objectListKeyPath = [self modelObjectListKeyPath];
    
    id mantleObjectListJSON = object;
    
    if (objectListKeyPath) { // 允许自定义转换的JSON节点
        mantleObjectListJSON = [object valueForKeyPath:objectListKeyPath];
    }
    
    if ([mantleObjectListJSON isKindOfClass:[NSArray class]]) {
        
        [self handleModelArrayWithArray:mantleObjectListJSON];
    }
}

/**
 *  尝试将字典转换成指定的Mantle对象，并保存在mantleObject中
 *
 *  @param dictionary 转换的字典
 */
- (void)handleModelObjectWithDictionary:(NSDictionary *)dictionary
{
    Class adapterClass = [self modelAdapterClass];
    
    NSAssert([adapterClass conformsToProtocol:@protocol(GQModelAdapter)], @"Must be implement GQModelAdapter protocol");
    
    Class mantleModelClass = [self modelObjectClass];
    
    id<GQModelAdapter> adapter = [[adapterClass alloc] initWithJSONObject:dictionary
                                                               modelClass:mantleModelClass];
    
    
    NSError *error;
    
    self.modelObject = [adapter modelObject];
    
    if (error) {
        [self logWithObject:[error localizedDescription]];
    }
}

/**
 *  尝试将数组转换成指定的Mantle列表，并保存在mantleObjectList中
 *
 *  @param array 转换的数组
 */
- (void)handleModelArrayWithArray:(NSArray *)array
{
    NSError *error;
    
    Class adapterClass = [self modelAdapterClass];
    
    NSAssert([adapterClass conformsToProtocol:@protocol(GQModelAdapter)], @"Must be implement GQModelAdapter protocol");
    
    Class modelClass = [self modelObjectListClass];
    id<GQModelAdapter> adapter = [[adapterClass alloc] initWithJSONObject:array
                                                               modelClass:modelClass];
    
    
    NSArray *models = [adapter modelObjectList];
    
    if (error) {
        [self logWithObject:[error localizedDescription]];
    }
    
    if (models) {
        if (self.modelObjectListUpdatePolicy == GQModelObjectListUpdatePolicyInsert) {
            if (self.modelObjectList == nil) {
                self.modelObjectList = [models mutableCopy];
            } else {
                [self.modelObjectList addObjectsFromArray:models];
            }
        } else if (self.modelObjectListUpdatePolicy == GQModelObjectListUpdatePolicyReplace) {
            self.modelObjectList = [models mutableCopy];
        }
    }
}

#pragma mark - UITableViewDataSource

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:self.cellIdentifier
                                                            forIndexPath:indexPath];
    
    id model = [self.modelObjectList objectAtIndex:indexPath.row];
    
    if (self.tableViewCellConfigureBlock) {
        self.tableViewCellConfigureBlock(cell, model);
    }
    
    return cell;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self.modelObjectList count];
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return [self.modelObjectList count];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:self.cellIdentifier forIndexPath:indexPath];
    
    id model = [self.modelObjectList objectAtIndex:indexPath.row];
    
    if (self.collectionViewCellConfigureBlock) {
        self.collectionViewCellConfigureBlock(cell, model);
    }
    
    return cell;
}


@end
