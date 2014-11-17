//
//  CCEffectBloom.m
//  cocos2d-ios
//
//  Created by Oleg Osin on 4/14/14.
//
//
//  This effect makes use of algorithms and GLSL shaders from GPUImage whose
//  license is included here.
//
//  <Begin GPUImage license>
//
//  Copyright (c) 2012, Brad Larson, Ben Cochran, Hugues Lismonde, Keitaroh
//  Kobayashi, Alaric Cole, Matthew Clark, Jacob Gundersen, Chris Williams.
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  Redistributions of source code must retain the above copyright notice, this
//  list of conditions and the following disclaimer.
//  Redistributions in binary form must reproduce the above copyright notice,
//  this list of conditions and the following disclaimer in the documentation
//  and/or other materials provided with the distribution.
//  Neither the name of the GPUImage framework nor the names of its contributors
//  may be used to endorse or promote products derived from this software
//  without specific prior written permission.
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
//  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//  POSSIBILITY OF SUCH DAMAGE.
//
//  <End GPUImage license>


#import "CCEffectBloom.h"
#import "CCEffect_Private.h"
#import "CCRenderer.h"
#import "CCTexture.h"


@interface CCEffectBloomImpl : CCEffectImpl
@property (nonatomic, weak) CCEffectBloom *interface;
@property (nonatomic, assign) float intensity;
@property (nonatomic, assign) float luminanceThreshold;
@end

@implementation CCEffectBloomImpl {
    NSUInteger _blurRadius;
    NSUInteger _numberOfOptimizedOffsets;
    GLfloat _sigma;
    NSUInteger _trueBlurRadius;
}

-(id)initWithInterface:(CCEffectBloom *)interface
{
    CCEffectUniform* u_intensity = [CCEffectUniform uniform:@"float" name:@"u_intensity" value:[NSNumber numberWithFloat:0.0f]];
    CCEffectUniform* u_luminanceThreshold = [CCEffectUniform uniform:@"float" name:@"u_luminanceThreshold" value:[NSNumber numberWithFloat:0.0f]];
    CCEffectUniform* u_enableGlowMap = [CCEffectUniform uniform:@"float" name:@"u_enableGlowMap" value:[NSNumber numberWithFloat:0.0f]];
    CCEffectUniform* u_blurDirection = [CCEffectUniform uniform:@"highp vec2" name:@"u_blurDirection"
                                                          value:[NSValue valueWithGLKVector2:GLKVector2Make(0.0f, 0.0f)]];
    
    NSArray *fragUniforms = @[u_enableGlowMap, u_luminanceThreshold, u_intensity, u_blurDirection];
    NSArray *vertUniforms = @[u_blurDirection];
    
    unsigned long count = (unsigned long)(1 + (_numberOfOptimizedOffsets * 2));
    CCEffectVarying* v_blurCoords = [CCEffectVarying varying:@"vec2" name:@"v_blurCoordinates" count:count];
    NSArray *varyings = @[v_blurCoords];
    
    NSArray *fragFunctions = [CCEffectBloomImpl buildFragmentFunctionsWithBlurRadius:_trueBlurRadius numberOfOptimizedOffsets:_numberOfOptimizedOffsets sigma:_sigma];
    NSArray *vertFunctions = [CCEffectBloomImpl buildVertexFunctionsWithBlurRadius:_trueBlurRadius numberOfOptimizedOffsets:_numberOfOptimizedOffsets sigma:_sigma];
    NSArray *renderPasses = [CCEffectBloomImpl buildRenderPassesWithInterface:interface];

    if((self = [super initWithRenderPasses:renderPasses fragmentFunctions:fragFunctions vertexFunctions:vertFunctions fragmentUniforms:fragUniforms vertexUniforms:vertUniforms varyings:varyings]))
    {
        self.interface = interface;
        self.debugName = @"CCEffectBloomImpl";
        self.stitchFlags = 0;
        return self;
    }
    
    return self;
}

-(void)setLuminanceThreshold:(float)luminanceThreshold
{
    _luminanceThreshold = clampf(luminanceThreshold, 0.0f, 1.0f);
}

-(void)setIntensity:(float)intensity
{
    _intensity = clampf(intensity, 0.0f, 1.0f);
}

-(void)setBlurRadius:(NSUInteger)blurRadius
{
    [self setBlurRadiusAndDependents:blurRadius];
}

- (void)setBlurRadiusAndDependents:(NSUInteger)blurRadius
{
    _trueBlurRadius = blurRadius;
    blurRadius = MIN(blurRadius, BLUR_OPTIMIZED_RADIUS_MAX);
    _blurRadius = blurRadius;
    _sigma = _trueBlurRadius / 2;
    if(_sigma == 0.0)
        _sigma = 1.0f;
    
    _numberOfOptimizedOffsets = MIN(blurRadius / 2 + (blurRadius % 2), BLUR_OPTIMIZED_RADIUS_MAX);
}

+ (NSArray *)buildFragmentFunctionsWithBlurRadius:(NSUInteger)trueBlurRadius numberOfOptimizedOffsets:(NSUInteger)numberOfOptimizedOffsets sigma:(GLfloat)sigma
{
    GLfloat *standardGaussianWeights = calloc(trueBlurRadius + 2, sizeof(GLfloat));
    GLfloat sumOfWeights = 0.0;
    for (NSUInteger currentGaussianWeightIndex = 0; currentGaussianWeightIndex < trueBlurRadius + 2; currentGaussianWeightIndex++)
    {
        standardGaussianWeights[currentGaussianWeightIndex] = (1.0 / sqrt(2.0 * M_PI * pow(sigma, 2.0))) * exp(-pow(currentGaussianWeightIndex, 2.0) / (2.0 * pow(sigma, 2.0)));
        
        if (currentGaussianWeightIndex == 0)
        {
            sumOfWeights += standardGaussianWeights[currentGaussianWeightIndex];
        }
        else
        {
            sumOfWeights += 2.0 * standardGaussianWeights[currentGaussianWeightIndex];
        }
    }
    
    // Next, normalize these weights to prevent the clipping of the Gaussian curve at the end of the discrete samples from reducing luminance
    for (NSUInteger currentGaussianWeightIndex = 0; currentGaussianWeightIndex < trueBlurRadius + 2; currentGaussianWeightIndex++)
    {
        standardGaussianWeights[currentGaussianWeightIndex] = standardGaussianWeights[currentGaussianWeightIndex] / sumOfWeights;
    }
    
    // From these weights we calculate the offsets to read interpolated values from
    NSUInteger trueNumberOfOptimizedOffsets = trueBlurRadius / 2;
    
    NSMutableString *shaderString = [[NSMutableString alloc] init];
    
    // Header
    [shaderString appendFormat:@"\
     lowp vec4 src = vec4(0.0);\n\
     lowp vec4 dst = vec4(0.0);\n\
     vec2 compare;\n\
     float inBounds;\n\
     vec2 blurCoords;\
     "];
    
    [shaderString appendString:@"if(u_enableGlowMap == 0.0) {\n"];
     
    [shaderString appendString:@"const vec3 luminanceWeighting = vec3(0.2125, 0.7154, 0.0721);\n"];
    [shaderString appendString:@"vec4 srcPixel; float luminanceCheck;\n"];

    // Inner texture loop
    [shaderString appendString:@"compare = cc_FragTexCoord1Extents - abs(v_blurCoordinates[0] - cc_FragTexCoord1Center);"];
    [shaderString appendString:@"inBounds = step(0.0, min(compare.x, compare.y));"];
    [shaderString appendFormat:@"srcPixel = texture2D(cc_PreviousPassTexture, v_blurCoordinates[0]);\n"];
    [shaderString appendString:@"luminanceCheck = step(u_luminanceThreshold, dot(srcPixel.rgb, luminanceWeighting));\n"];
    [shaderString appendFormat:@"src += inBounds * luminanceCheck * srcPixel * %f;\n", (trueBlurRadius == 0) ? 1.0 : standardGaussianWeights[0]];
    
    for (NSUInteger currentBlurCoordinateIndex = 0; currentBlurCoordinateIndex < numberOfOptimizedOffsets; currentBlurCoordinateIndex++)
    {
        GLfloat firstWeight = standardGaussianWeights[currentBlurCoordinateIndex * 2 + 1];
        GLfloat secondWeight = standardGaussianWeights[currentBlurCoordinateIndex * 2 + 2];
        GLfloat optimizedWeight = firstWeight + secondWeight;

        [shaderString appendFormat:@"blurCoords = v_blurCoordinates[%lu];", (unsigned long)((currentBlurCoordinateIndex * 2) + 1)];
        [shaderString appendString:@"compare = cc_FragTexCoord1Extents - abs(blurCoords - cc_FragTexCoord1Center);"];
        [shaderString appendString:@"inBounds = step(0.0, min(compare.x, compare.y));"];
        [shaderString appendFormat:@"srcPixel = texture2D(cc_PreviousPassTexture, blurCoords);\n"];
        [shaderString appendString:@"luminanceCheck = step(u_luminanceThreshold, dot(srcPixel.rgb, luminanceWeighting));\n"];
        [shaderString appendFormat:@"src += inBounds * luminanceCheck * srcPixel * %f;\n", optimizedWeight];

        [shaderString appendFormat:@"blurCoords = v_blurCoordinates[%lu];", (unsigned long)((currentBlurCoordinateIndex * 2) + 2)];
        [shaderString appendString:@"compare = cc_FragTexCoord1Extents - abs(blurCoords - cc_FragTexCoord1Center);"];
        [shaderString appendString:@"inBounds = step(0.0, min(compare.x, compare.y));"];
        [shaderString appendFormat:@"srcPixel = texture2D(cc_PreviousPassTexture, blurCoords);\n"];
        [shaderString appendString:@"luminanceCheck = step(u_luminanceThreshold, dot(srcPixel.rgb, luminanceWeighting));\n"];
        [shaderString appendFormat:@"src += inBounds * luminanceCheck * srcPixel * %f;\n", optimizedWeight];
    }
    
    // If the number of required samples exceeds the amount we can pass in via varyings, we have to do dependent texture reads in the fragment shader
    if (trueNumberOfOptimizedOffsets > numberOfOptimizedOffsets)
    {
        [shaderString appendString:@"highp vec2 singleStepOffset = u_blurDirection;\n"];
        
        for (NSUInteger currentOverlowTextureRead = numberOfOptimizedOffsets; currentOverlowTextureRead < trueNumberOfOptimizedOffsets; currentOverlowTextureRead++)
        {
            GLfloat firstWeight = standardGaussianWeights[currentOverlowTextureRead * 2 + 1];
            GLfloat secondWeight = standardGaussianWeights[currentOverlowTextureRead * 2 + 2];
            
            GLfloat optimizedWeight = firstWeight + secondWeight;
            GLfloat optimizedOffset = (firstWeight * (currentOverlowTextureRead * 2 + 1) + secondWeight * (currentOverlowTextureRead * 2 + 2)) / optimizedWeight;

            [shaderString appendFormat:@"blurCoords = v_blurCoordinates[0] + singleStepOffset * %f;\n", optimizedOffset];
            [shaderString appendString:@"compare = cc_FragTexCoord1Extents - abs(blurCoords - cc_FragTexCoord1Center);"];
            [shaderString appendString:@"inBounds = step(0.0, min(compare.x, compare.y));"];
            [shaderString appendFormat:@"srcPixel = texture2D(cc_PreviousPassTexture, blurCoords);\n"];
            [shaderString appendString:@"luminanceCheck = step(u_luminanceThreshold, dot(srcPixel.rgb, luminanceWeighting));\n"];
            [shaderString appendFormat:@"src += inBounds * luminanceCheck * srcPixel * %f;\n", optimizedWeight];

            [shaderString appendFormat:@"blurCoords = v_blurCoordinates[0] - singleStepOffset * %f;\n", optimizedOffset];
            [shaderString appendString:@"compare = cc_FragTexCoord1Extents - abs(blurCoords - cc_FragTexCoord1Center);"];
            [shaderString appendString:@"inBounds = step(0.0, min(compare.x, compare.y));"];
            [shaderString appendFormat:@"srcPixel = texture2D(cc_PreviousPassTexture, blurCoords);\n"];
            [shaderString appendString:@"luminanceCheck = step(u_luminanceThreshold, dot(srcPixel.rgb, luminanceWeighting));\n"];
            [shaderString appendFormat:@"src += inBounds * luminanceCheck * srcPixel * %f;\n", optimizedWeight];
        }
    }
    
    [shaderString appendString:@"} else {\n"];
    [shaderString appendString:@"\
        compare = cc_FragTexCoord2Extents - abs(cc_FragTexCoord2 - cc_FragTexCoord2Center); \
        inBounds = step(0.0, min(compare.x, compare.y)); \
        dst = texture2D(cc_MainTexture, cc_FragTexCoord2) * inBounds;\
        src = texture2D(cc_PreviousPassTexture, cc_FragTexCoord1);\
     }\n"];
    
    
    // Choose one?
    // TODO: try using min(src, dst) to create a gloomEffect
    // NSString* additiveBlending =  @"src + dst";
    NSString* screenBlending = @"(src * u_intensity + dst) - ((src * dst) * u_intensity)";
    
    [shaderString appendFormat:@"\
     return %@;\n", screenBlending];

    free(standardGaussianWeights);
    
    CCEffectFunction* fragmentFunction = [[CCEffectFunction alloc] initWithName:@"bloomEffect" body:shaderString inputs:nil returnType:@"vec4"];
    return @[fragmentFunction];
}

+ (NSArray *)buildVertexFunctionsWithBlurRadius:(NSUInteger)trueBlurRadius numberOfOptimizedOffsets:(NSUInteger)numberOfOptimizedOffsets sigma:(GLfloat)sigma
{
    GLfloat* standardGaussianWeights = calloc(trueBlurRadius + 1, sizeof(GLfloat));
    GLfloat sumOfWeights = 0.0;
    for (NSUInteger currentGaussianWeightIndex = 0; currentGaussianWeightIndex < trueBlurRadius + 1; currentGaussianWeightIndex++)
    {
        standardGaussianWeights[currentGaussianWeightIndex] = (1.0 / sqrt(2.0 * M_PI * pow(sigma, 2.0))) * exp(-pow(currentGaussianWeightIndex, 2.0) / (2.0 * pow(sigma, 2.0)));
        
        if (currentGaussianWeightIndex == 0)
        {
            sumOfWeights += standardGaussianWeights[currentGaussianWeightIndex];
        }
        else
        {
            sumOfWeights += 2.0 * standardGaussianWeights[currentGaussianWeightIndex];
        }
    }
    
    // Next, normalize these weights to prevent the clipping of the Gaussian curve at the end of the discrete samples from reducing luminance
    for (NSUInteger currentGaussianWeightIndex = 0; currentGaussianWeightIndex < trueBlurRadius + 1; currentGaussianWeightIndex++)
    {
        standardGaussianWeights[currentGaussianWeightIndex] = standardGaussianWeights[currentGaussianWeightIndex] / sumOfWeights;
    }
    
    // From these weights we calculate the offsets to read interpolated values from
    GLfloat* optimizedGaussianOffsets = calloc(numberOfOptimizedOffsets, sizeof(GLfloat));
    
    for (NSUInteger currentOptimizedOffset = 0; currentOptimizedOffset < numberOfOptimizedOffsets; currentOptimizedOffset++)
    {
        GLfloat firstWeight = standardGaussianWeights[currentOptimizedOffset*2 + 1];
        GLfloat secondWeight = standardGaussianWeights[currentOptimizedOffset*2 + 2];
        
        GLfloat optimizedWeight = firstWeight + secondWeight;
        
        optimizedGaussianOffsets[currentOptimizedOffset] = (firstWeight * (currentOptimizedOffset*2 + 1) + secondWeight * (currentOptimizedOffset*2 + 2)) / optimizedWeight;
    }
    
    NSMutableString *shaderString = [[NSMutableString alloc] init];

    [shaderString appendString:@"\
     \n\
     vec2 singleStepOffset = u_blurDirection;\n"];
    
    // Inner offset loop
    [shaderString appendString:@"v_blurCoordinates[0] = cc_TexCoord1.xy;\n"];
    for (NSUInteger currentOptimizedOffset = 0; currentOptimizedOffset < numberOfOptimizedOffsets; currentOptimizedOffset++)
    {
        [shaderString appendFormat:@"\
         v_blurCoordinates[%lu] = cc_TexCoord1.xy + singleStepOffset * %f;\n\
         v_blurCoordinates[%lu] = cc_TexCoord1.xy - singleStepOffset * %f;\n", (unsigned long)((currentOptimizedOffset * 2) + 1), optimizedGaussianOffsets[currentOptimizedOffset], (unsigned long)((currentOptimizedOffset * 2) + 2), optimizedGaussianOffsets[currentOptimizedOffset]];
    }
    

    [shaderString appendString:@"return cc_Position;\n"];
    
    free(optimizedGaussianOffsets);
    free(standardGaussianWeights);
    
    CCEffectFunction* vertexFunction = [[CCEffectFunction alloc] initWithName:@"bloomEffect" body:shaderString inputs:nil returnType:@"vec4"];
    return @[vertexFunction];
}

+ (NSArray *)buildRenderPassesWithInterface:(CCEffectBloom *)interface
{
    // optmized approach based on linear sampling - http://rastergrid.com/blog/2010/09/efficient-gaussian-blur-with-linear-sampling/ and GPUImage - https://github.com/BradLarson/GPUImage
    // pass 0: blurs (horizontal) texture[0] and outputs blurmap to texture[1]
    // pass 1: blurs (vertical) texture[1] and outputs to texture[2]
    // pass 2: blends texture[0] and texture[2] and outputs to texture[3]

    __weak CCEffectBloom *weakInterface = interface;

    CCEffectRenderPass *pass0 = [[CCEffectRenderPass alloc] initWithIndex:0];
    pass0.debugLabel = @"CCEffectBloom pass 0";
    pass0.beginBlocks = @[[^(CCEffectRenderPass *pass, CCEffectRenderPassInputs *passInputs){

        // Why not just use self (or "__weak self" really)? Because at the time these blocks are created,
        // self is not necesssarily valid.
        CCEffectBloomImpl *impl = (CCEffectBloomImpl *)weakInterface.effectImpl;

        passInputs.shaderUniforms[CCShaderUniformMainTexture] = passInputs.previousPassTexture;
        passInputs.shaderUniforms[CCShaderUniformPreviousPassTexture] = passInputs.previousPassTexture;
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Center] = [NSValue valueWithGLKVector2:passInputs.texCoord1Center];
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Extents] = [NSValue valueWithGLKVector2:passInputs.texCoord1Extents];

        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_enableGlowMap"]] = [NSNumber numberWithFloat:0.0f];
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_luminanceThreshold"]] = [NSNumber numberWithFloat:impl.luminanceThreshold];
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_intensity"]] = [NSNumber numberWithFloat:impl.intensity];
        
        GLKVector2 dur = GLKVector2Make(1.0 / (passInputs.previousPassTexture.pixelWidth / passInputs.previousPassTexture.contentScale), 0.0);
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_blurDirection"]] = [NSValue valueWithGLKVector2:dur];
        
    } copy]];
    
    
    CCEffectRenderPass *pass1 = [[CCEffectRenderPass alloc] initWithIndex:1];
    pass1.debugLabel = @"CCEffectBloom pass 1";
    pass1.beginBlocks = @[[^(CCEffectRenderPass *pass, CCEffectRenderPassInputs *passInputs){

        // Why not just use self (or "__weak self" really)? Because at the time these blocks are created,
        // self is not necesssarily valid.
        CCEffectBloomImpl *impl = (CCEffectBloomImpl *)weakInterface.effectImpl;

        passInputs.shaderUniforms[CCShaderUniformPreviousPassTexture] = passInputs.previousPassTexture;
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Center] = [NSValue valueWithGLKVector2:GLKVector2Make(0.5f, 0.5f)];
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Extents] = [NSValue valueWithGLKVector2:GLKVector2Make(1.0f, 1.0f)];
        
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_enableGlowMap"]] = [NSNumber numberWithFloat:0.0f];
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_luminanceThreshold"]] = [NSNumber numberWithFloat:0.0f];
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_intensity"]] = [NSNumber numberWithFloat:impl.intensity];
        
        GLKVector2 dur = GLKVector2Make(0.0, 1.0 / (passInputs.previousPassTexture.pixelHeight / passInputs.previousPassTexture.contentScale));
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_blurDirection"]] = [NSValue valueWithGLKVector2:dur];
        
    } copy]];

    
    CCEffectRenderPass *pass2 = [[CCEffectRenderPass alloc] initWithIndex:2];
    pass2.debugLabel = @"CCEffectBloom pass 2";
    pass2.texCoord1Mapping = CCEffectTexCoordMapPreviousPassTex;
    pass2.texCoord2Mapping = CCEffectTexCoordMapMainTex;
    pass2.beginBlocks = @[[^(CCEffectRenderPass *pass, CCEffectRenderPassInputs *passInputs){

        // Why not just use self (or "__weak self" really)? Because at the time these blocks are created,
        // self is not necesssarily valid.
        CCEffectBloomImpl *impl = (CCEffectBloomImpl *)weakInterface.effectImpl;

        passInputs.shaderUniforms[CCShaderUniformPreviousPassTexture] = passInputs.previousPassTexture;
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Center] = [NSValue valueWithGLKVector2:GLKVector2Make(0.5f, 0.5f)];
        passInputs.shaderUniforms[CCShaderUniformTexCoord1Extents] = [NSValue valueWithGLKVector2:GLKVector2Make(1.0f, 1.0f)];
        passInputs.shaderUniforms[CCShaderUniformTexCoord2Center] = [NSValue valueWithGLKVector2:passInputs.texCoord1Center];
        passInputs.shaderUniforms[CCShaderUniformTexCoord2Extents] = [NSValue valueWithGLKVector2:passInputs.texCoord1Extents];

        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_enableGlowMap"]] = [NSNumber numberWithFloat:1.0f];
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_luminanceThreshold"]] = [NSNumber numberWithFloat:0.0f];
        passInputs.shaderUniforms[pass.uniformTranslationTable[@"u_intensity"]] = [NSNumber numberWithFloat:impl.intensity];
        
    } copy]];

    return @[pass0, pass1, pass2];
}

@end


@implementation CCEffectBloom
{
    BOOL _shaderDirty;
}

-(id)init
{
    if((self = [self initWithPixelBlurRadius:2 intensity:1.0f luminanceThreshold:0.0f]))
    {
        return self;
    }
    
    return self;
}

-(id)initWithPixelBlurRadius:(NSUInteger)blurRadius intensity:(float)intensity luminanceThreshold:(float)luminanceThreshold
{
    if(self = [super init])
    {
        self.blurRadius = blurRadius;
        self.intensity = intensity;
        self.luminanceThreshold = luminanceThreshold;
        
        self.effectImpl = [[CCEffectBloomImpl alloc] initWithInterface:self];
        self.debugName = @"CCEffectBloom";
        return self;
    }

    return self;
}

+(id)effectWithBlurRadius:(NSUInteger)blurRadius intensity:(float)intensity luminanceThreshold:(float)luminanceThreshold
{
    return [[self alloc] initWithPixelBlurRadius:blurRadius intensity:intensity luminanceThreshold:luminanceThreshold];
}

-(void)setLuminanceThreshold:(float)luminanceThreshold
{
    _luminanceThreshold = luminanceThreshold;

    CCEffectBloomImpl *bloomImpl = (CCEffectBloomImpl *)self.effectImpl;
    [bloomImpl setLuminanceThreshold:luminanceThreshold];
}

-(void)setIntensity:(float)intensity
{
    _intensity = intensity;
    
    CCEffectBloomImpl *bloomImpl = (CCEffectBloomImpl *)self.effectImpl;
    [bloomImpl setIntensity:intensity];
}

-(void)setBlurRadius:(NSUInteger)blurRadius
{
    _blurRadius = blurRadius;

    CCEffectBloomImpl *bloomImpl = (CCEffectBloomImpl *)self.effectImpl;
    [bloomImpl setBlurRadius:blurRadius];
    
    // The shader is constructed dynamically based on the blur radius
    // so mark it dirty.
    _shaderDirty = YES;
    
    // Now inform any containing stacks that this effect is dirty.
    [self.owningStack passesDidChange:self];
}

- (CCEffectPrepareStatus)prepareForRendering
{
    CCEffectPrepareStatus result = CCEffectPrepareNothingToDo;
    if (_shaderDirty)
    {
        self.effectImpl = [[CCEffectBloomImpl alloc] initWithInterface:self];
        
        _shaderDirty = NO;
        result = CCEffectPrepareSuccess;
    }
    return result;
}

@end

